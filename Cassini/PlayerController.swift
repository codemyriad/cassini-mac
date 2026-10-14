import AppKit
import AVFoundation
import MediaPlayer
import Observation

/// Plays the audio and is the one source of truth for the current time.
///
/// Playback goes through `AVAudioEngine` fed from `AVAudioFile`, not `AVPlayer`: CoreMedia's Ogg
/// demuxer seeks by byte estimate and lands up to two seconds away from the time it reports, and
/// its duration is an estimate too. `AVAudioFile` decodes frame-exactly, so the clock below is
/// the file position the renderer is actually playing.
@MainActor
@Observable
final class PlayerController {
    static let speeds: [Double] = [0.75, 1, 1.25, 1.5, 2]
    /// The order the speed button cycles through, as in the design.
    static let cycleOrder: [Double] = [1, 1.25, 1.5, 2, 0.75]
    static let skipMs = 15_000

    private(set) var isPlaying = false
    /// Playback position in ms, refreshed on every display refresh while playing.
    private(set) var currentMs = 0
    private(set) var durationMs: Int
    /// Why the audio cannot play, when it cannot.
    private(set) var playbackError: String?
    var speed: Double = 1 {
        didSet {
            timePitch.rate = Float(speed)
            updateNowPlaying()
        }
    }

    let title: String

    @ObservationIgnored private let engine = AVAudioEngine()
    @ObservationIgnored private let node = AVAudioPlayerNode()
    @ObservationIgnored private let timePitch = AVAudioUnitTimePitch()
    @ObservationIgnored private var file: AVAudioFile?
    @ObservationIgnored private var sampleRate: Double = 48000
    /// The file frame the current schedule started at; the node's player time counts from here.
    @ObservationIgnored private var segmentStart: AVAudioFramePosition = 0
    /// The position while paused.
    @ObservationIgnored private var pausedFrame: AVAudioFramePosition = 0
    /// Bumped on every schedule or stop, so a stale segment's completion is ignored.
    @ObservationIgnored private var scheduleGeneration = 0
    @ObservationIgnored private var clock: CADisplayLink?
    @ObservationIgnored private var clockTarget: ClockTarget?
    @ObservationIgnored private var configObserver: NSObjectProtocol?
    /// Called on every clock update with the time in ms. Not observed, so views that only need
    /// frame-rate updates can subscribe here without re-rendering the whole hierarchy.
    @ObservationIgnored var tickHandlers: [(Int) -> Void] = []

    /// The controller remote commands (media keys, Control Center) address: the last one that played.
    @ObservationIgnored private static weak var active: PlayerController?
    @ObservationIgnored private static var remoteCommandsInstalled = false

    init(url: URL, durationMs: Int, title: String) {
        self.durationMs = durationMs
        self.title = title
        do {
            let f = try AVAudioFile(forReading: url)
            file = f
            sampleRate = f.processingFormat.sampleRate
            if durationMs == 0 {
                self.durationMs = Int((Double(f.length) * 1000 / sampleRate).rounded(.down))
            }
            engine.attach(node)
            engine.attach(timePitch)
            engine.connect(node, to: timePitch, format: f.processingFormat)
            engine.connect(timePitch, to: engine.mainMixerNode, format: f.processingFormat)
            engine.prepare()
        } catch {
            playbackError = (error as NSError).localizedFailureReason ?? error.localizedDescription
        }
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.engineConfigurationChanged() }
        }
    }

    deinit {
        clock?.invalidate()
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
    }

    // MARK: Transport

    func play() {
        guard !isPlaying, playbackError == nil, file != nil else { return }
        if durationMs > 0, currentMs >= durationMs - 50 {
            pausedFrame = 0
            publish(ms: 0)
        }
        do {
            if !engine.isRunning { try engine.start() }
        } catch {
            playbackError = error.localizedDescription
            return
        }
        guard schedule(from: pausedFrame) else { return }
        node.play()
        isPlaying = true
        startClock()
        PlayerController.active = self
        PlayerController.installRemoteCommands()
        updateNowPlaying()
    }

    func pause() {
        guard isPlaying else { return }
        pausedFrame = frameNow()
        scheduleGeneration += 1
        node.stop()
        isPlaying = false
        stopClock()
        publish(ms: ms(for: pausedFrame))
        updateNowPlaying()
    }

    func toggle() { isPlaying ? pause() : play() }

    /// Seeks exactly and publishes the new time at once, so a highlight lands in the same frame.
    func seek(toMs ms: Int) {
        let clamped = max(0, min(ms, max(durationMs, 0)))
        let frame = AVAudioFramePosition((Double(clamped) * sampleRate / 1000).rounded())
        if isPlaying {
            if schedule(from: frame) { node.play() } else { return }
        } else {
            pausedFrame = frame
        }
        publish(ms: clamped)
        updateNowPlaying()
    }

    func skip(by deltaMs: Int) { seek(toMs: currentMs + deltaMs) }

    func cycleSpeed() {
        let order = PlayerController.cycleOrder
        let i = order.firstIndex(of: speed) ?? 0
        speed = order[(i + 1) % order.count]
    }

    func stepSpeed(_ direction: Int) {
        let s = PlayerController.speeds
        let i = s.firstIndex(of: speed) ?? 1
        speed = s[max(0, min(s.count - 1, i + direction))]
    }

    /// Stops playback for good; called when the document window closes.
    func shutDown() {
        pause()
        engine.stop()
        if PlayerController.active === self {
            PlayerController.active = nil
            let center = MPNowPlayingInfoCenter.default()
            center.nowPlayingInfo = nil
            center.playbackState = .stopped
        }
    }

    // MARK: Scheduling

    /// Schedules the file from `frame` to its end. Returns false (and ends playback) at the end.
    private func schedule(from frame: AVAudioFramePosition) -> Bool {
        guard let file else { return false }
        scheduleGeneration += 1
        node.stop()
        let remaining = file.length - frame
        guard remaining > 0 else {
            reachedEnd()
            return false
        }
        segmentStart = frame
        let generation = scheduleGeneration
        node.scheduleSegment(file, startingFrame: frame, frameCount: AVAudioFrameCount(remaining), at: nil,
                             completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in
                guard let self, generation == self.scheduleGeneration, self.isPlaying else { return }
                self.reachedEnd()
            }
        }
        return true
    }

    private func reachedEnd() {
        scheduleGeneration += 1
        node.stop()
        isPlaying = false
        stopClock()
        pausedFrame = file?.length ?? 0
        publish(ms: durationMs)
        updateNowPlaying()
    }

    private func engineConfigurationChanged() {
        // The output device changed; the engine stopped. Resume from where we were.
        guard isPlaying else { return }
        let frame = frameNow()
        do {
            try engine.start()
        } catch {
            pausedFrame = frame
            isPlaying = false
            stopClock()
            playbackError = error.localizedDescription
            return
        }
        if schedule(from: frame) { node.play() }
    }

    // MARK: Clock

    private func frameNow() -> AVAudioFramePosition {
        guard isPlaying else { return pausedFrame }
        guard let nodeTime = node.lastRenderTime, let playerTime = node.playerTime(forNodeTime: nodeTime) else {
            return segmentStart
        }
        return max(segmentStart, segmentStart + playerTime.sampleTime)
    }

    private func ms(for frame: AVAudioFramePosition) -> Int {
        Int((Double(frame) * 1000 / sampleRate).rounded(.down))
    }

    private func startClock() {
        guard clock == nil, let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        // CADisplayLink retains its target; the proxy keeps it from retaining this controller.
        let target = ClockTarget()
        target.owner = self
        clockTarget = target
        let link = screen.displayLink(target: target, selector: #selector(ClockTarget.step))
        link.add(to: .main, forMode: .common)
        clock = link
    }

    private func stopClock() {
        clock?.invalidate()
        clock = nil
        clockTarget = nil
    }

    fileprivate func tick() {
        guard isPlaying else { return }
        let ms = ms(for: frameNow())
        if durationMs > 0, ms >= durationMs {
            reachedEnd()
            return
        }
        publish(ms: ms)
    }

    private func publish(ms: Int) {
        if ms != currentMs { currentMs = ms }
        for handler in tickHandlers { handler(ms) }
    }

    // MARK: Now Playing

    private func updateNowPlaying() {
        guard PlayerController.active === self else { return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: title,
            MPMediaItemPropertyPlaybackDuration: Double(durationMs) / 1000,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: Double(currentMs) / 1000,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? speed : 0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: speed,
        ]
        info[MPNowPlayingInfoPropertyMediaType] = MPNowPlayingInfoMediaType.audio.rawValue
        let center = MPNowPlayingInfoCenter.default()
        center.nowPlayingInfo = info
        center.playbackState = isPlaying ? .playing : .paused
    }

    private static func installRemoteCommands() {
        guard !remoteCommandsInstalled else { return }
        remoteCommandsInstalled = true
        let c = MPRemoteCommandCenter.shared()
        c.playCommand.addTarget { _ in MainActor.assumeIsolated { active?.play() }; return .success }
        c.pauseCommand.addTarget { _ in MainActor.assumeIsolated { active?.pause() }; return .success }
        c.togglePlayPauseCommand.addTarget { _ in MainActor.assumeIsolated { active?.toggle() }; return .success }
        c.skipForwardCommand.preferredIntervals = [NSNumber(value: skipMs / 1000)]
        c.skipForwardCommand.addTarget { _ in MainActor.assumeIsolated { active?.skip(by: skipMs) }; return .success }
        c.skipBackwardCommand.preferredIntervals = [NSNumber(value: skipMs / 1000)]
        c.skipBackwardCommand.addTarget { _ in MainActor.assumeIsolated { active?.skip(by: -skipMs) }; return .success }
        c.changePlaybackPositionCommand.addTarget { event in
            guard let e = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            MainActor.assumeIsolated { active?.seek(toMs: Int(e.positionTime * 1000)) }
            return .success
        }
    }
}

/// The display link's target. CADisplayLink retains its target, so this stands between it and the
/// controller, which can then be released when its window closes.
private final class ClockTarget: NSObject {
    weak var owner: PlayerController?

    @objc func step() {
        MainActor.assumeIsolated { owner?.tick() }
    }
}
