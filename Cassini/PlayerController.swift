import AppKit
import AVFoundation
import MediaPlayer
import Observation

/// Plays the audio and is the one source of truth for the current time.
@MainActor
@Observable
final class PlayerController: NSObject {
    static let speeds: [Double] = [0.75, 1, 1.25, 1.5, 2]
    /// The order the speed button cycles through, as in the design.
    static let cycleOrder: [Double] = [1, 1.25, 1.5, 2, 0.75]
    static let skipMs = 15_000

    private(set) var isPlaying = false
    /// Playback position in ms, refreshed on every display refresh while playing.
    private(set) var currentMs = 0
    private(set) var durationMs: Int
    var speed: Double = 1 {
        didSet {
            if isPlaying { player.rate = Float(speed) }
            updateNowPlaying()
        }
    }

    let title: String

    @ObservationIgnored private let player: AVPlayer
    @ObservationIgnored private var displayLink: CADisplayLink?
    @ObservationIgnored private var endObserver: NSObjectProtocol?
    @ObservationIgnored private var statusObservation: NSKeyValueObservation?
    /// Called on every clock update with the time in ms. Not observed, so views that only need
    /// frame-rate updates can subscribe here without re-rendering the whole hierarchy.
    @ObservationIgnored var tickHandlers: [(Int) -> Void] = []

    /// The controller remote commands (media keys, Control Center) address: the last one that played.
    @ObservationIgnored private static weak var active: PlayerController?
    @ObservationIgnored private static var remoteCommandsInstalled = false

    init(url: URL, durationMs: Int, title: String) {
        let item = AVPlayerItem(url: url)
        item.audioTimePitchAlgorithm = .timeDomain
        player = AVPlayer(playerItem: item)
        player.actionAtItemEnd = .pause
        self.durationMs = durationMs
        self.title = title
        super.init()

        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reachedEnd() }
        }
        statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            Task { @MainActor in
                guard let self, item.status == .readyToPlay else { return }
                let d = item.duration.seconds
                if self.durationMs == 0, d.isFinite { self.durationMs = Int(d * 1000) }
                self.updateNowPlaying()
            }
        }
    }

    deinit {
        displayLink?.invalidate()
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
    }

    // MARK: Transport

    func play() {
        guard !isPlaying else { return }
        if durationMs > 0, currentMs >= durationMs - 50 { seek(toMs: 0) }
        isPlaying = true
        player.rate = Float(speed)
        startClock()
        PlayerController.active = self
        PlayerController.installRemoteCommands()
        updateNowPlaying()
    }

    func pause() {
        guard isPlaying else { return }
        isPlaying = false
        player.rate = 0
        stopClock()
        tick()
        updateNowPlaying()
    }

    func toggle() { isPlaying ? pause() : play() }

    /// Seeks exactly and publishes the new time at once, so a highlight lands in the same frame.
    func seek(toMs ms: Int) {
        let clamped = max(0, min(ms, max(durationMs, 0)))
        let time = CMTime(value: CMTimeValue(clamped), timescale: 1000)
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
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

    private func reachedEnd() {
        isPlaying = false
        stopClock()
        publish(ms: durationMs)
        updateNowPlaying()
    }

    // MARK: Clock

    private func startClock() {
        guard displayLink == nil, let screen = NSScreen.main else { return }
        let link = screen.displayLink(target: self, selector: #selector(step))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func stopClock() {
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func step() { tick() }

    private func tick() {
        let seconds = player.currentTime().seconds
        guard seconds.isFinite else { return }
        publish(ms: Int((seconds * 1000).rounded()))
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
