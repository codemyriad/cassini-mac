// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation

/// Resource teardown is independent of actor-isolated callbacks and also runs
/// when an owner disappears without an explicit stop().
private final class PlayerResources: @unchecked Sendable {
    let player: AVPlayer
    var timeline: SessionTimeline?
    var observations: [NSKeyValueObservation] = []
    var notifications: [NSObjectProtocol] = []
    var timeObserver: Any?
    var boundaryObserver: Any?
    @MainActor init(_ timeline: SessionTimeline, player: AVPlayer) {
        self.timeline = timeline; self.player = player
        player.replaceCurrentItem(with:AVPlayerItem(asset:timeline.asset))
    }
    func close() {
        observations.forEach { $0.invalidate() }; observations = []
        notifications.forEach { NotificationCenter.default.removeObserver($0) }; notifications = []
        if let timeObserver { player.removeTimeObserver(timeObserver); self.timeObserver = nil }
        if let boundaryObserver { player.removeTimeObserver(boundaryObserver); self.boundaryObserver = nil }
        player.pause(); player.replaceCurrentItem(with: nil); timeline = nil
    }
    deinit { close() }
}
@MainActor final class AVSessionTransport: SessionTransport {
    var onState: ((SessionTransportState) -> Void)?
    var onEnd: (() -> Void)?
    var onFailure: ((Error) -> Void)?
    var onPosition: ((Double) -> Void)?
    private var rate: Float = 1
    private let resources: PlayerResources
    private var boundary: (end: Double, token: Int, done: @MainActor @Sendable () -> Void)?
    private var boundarySerial = 0
    private var seekSerial = 0
    private var seeking = false
    private var boundaryFinished = false
    var positionMs: Double {
        let ms = resources.player.currentTime().seconds * 1000
        return ms.isFinite ? max(0,ms) : 0
    }
    init(_ timeline: SessionTimeline, player: AVPlayer = AVPlayer()) {
        resources = PlayerResources(timeline,player:player)
        let player = resources.player, item = player.currentItem!
        resources.observations = [
            player.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.timeControlStatusChanged()
                }
            },
            item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
                if let error = item.status == .failed ? item.error : nil { Task { @MainActor in self?.onFailure?(error) } }
            }
        ]
        resources.notifications = [
            NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reachedEnd() }
            },
            NotificationCenter.default.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main) { [weak self] note in
                let error = note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error ?? CocoaError(.fileReadUnknown)
                MainActor.assumeIsolated { self?.onFailure?(error) }
            }
        ]
        resources.timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.05, preferredTimescale: 1000), queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.seeking else { return }
                self.onPosition?(self.positionMs) // an old tick cannot undo a newer seek
            }
        }
    }
    // Read live state; an old queued KVO event cannot undo a newer request.
    func timeControlStatusChanged() {
        switch resources.player.timeControlStatus {
        case .playing: onState?(.playing)
        case .waitingToPlayAtSpecifiedRate: onState?(.waiting)
        default:
            // forwardPlaybackEndTime can pause before its boundary/EOS callback.
            // Complete first: forwarding this pause would cancel the owner's play
            // intent, including a next span started reentrantly by the completion.
            if seeking || boundaryFinished || finishBoundaryIfReached() { return }
            onState?(.paused)
        }
    }
    func play() { boundaryFinished = false; resources.player.playImmediately(atRate: rate) }
    func setRate(_ rate: Float) {
        self.rate = rate
        // A queued boundary/end notification must not let a rate change restart a
        // span whose media has already ended, or change the span its callback starts.
        if finishBoundaryIfReached() { return }
        if !seeking, resources.player.rate != 0 { resources.player.rate = rate }
    }
    func pause() { resources.player.pause() }
    func rewind(_ completion: @escaping @MainActor @Sendable (Bool) -> Void) {
        seek(toMs: 0, completion: completion)
    }
    func seek(toMs: Double, completion: @escaping @MainActor @Sendable (Bool) -> Void) {
        seekSerial += 1
        let serial = seekSerial
        seeking = true; boundaryFinished = false
        resources.player.seek(to: CMTime(seconds: toMs / 1000, preferredTimescale: 1_000_000), toleranceBefore: .zero, toleranceAfter: .zero) { finished in
            Task { @MainActor [weak self] in
                guard let self, serial == self.seekSerial else { return }
                self.seeking = false; completion(finished)
            }
        }
    }
    func setBoundary(atMs end: Double, completion: @escaping @MainActor @Sendable () -> Void) {
        clearBoundary()
        let token = boundarySerial
        boundary = (end,token,completion); boundaryFinished = false
        let time = CMTime(seconds:end/1000,preferredTimescale:1_000_000)
        // forwardPlaybackEndTime enforces the media stop even while the main queue
        // is busy; the boundary observer is the event that advances listening.
        resources.player.currentItem?.forwardPlaybackEndTime = time
        resources.boundaryObserver = resources.player.addBoundaryTimeObserver(forTimes:[NSValue(time:time)],queue:.main) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.boundary?.token == token else { return }
                _ = self.finishBoundaryIfReached()
            }
        }
    }
    func clearBoundary() {
        boundarySerial += 1; boundary = nil
        if let observer = resources.boundaryObserver { resources.player.removeTimeObserver(observer); resources.boundaryObserver = nil }
        resources.player.currentItem?.forwardPlaybackEndTime = .invalid
    }
    @discardableResult private func finishBoundaryIfReached() -> Bool {
        guard !seeking, let boundary, positionMs >= boundary.end - SessionBoundary.toleranceMs else { return false }
        resources.player.pause(); boundaryFinished = true
        clearBoundary(); onPosition?(boundary.end)
        boundary.done()
        return true
    }
    private func reachedEnd() {
        guard !seeking, !boundaryFinished else { return }
        if boundary != nil { _ = finishBoundaryIfReached(); return }
        // Notifications queued by the preceding span cannot rewind a new seek/span.
        guard let duration = resources.timeline?.durationMs, positionMs >= duration - SessionBoundary.toleranceMs else { return }
        onEnd?()
    }
    func close() {
        seekSerial += 1; clearBoundary()
        onState = nil; onEnd = nil; onFailure = nil; onPosition = nil; resources.close()
    }
}
