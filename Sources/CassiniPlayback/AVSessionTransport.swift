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
    @MainActor init(_ timeline: SessionTimeline) { self.timeline = timeline; player = AVPlayer(playerItem: AVPlayerItem(asset: timeline.asset)) }
    func close() {
        observations.forEach { $0.invalidate() }; observations = []
        notifications.forEach { NotificationCenter.default.removeObserver($0) }; notifications = []
        if let timeObserver { player.removeTimeObserver(timeObserver); self.timeObserver = nil }
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
    init(_ timeline: SessionTimeline) {
        resources = PlayerResources(timeline)
        let player = resources.player, item = player.currentItem!
        resources.observations = [
            player.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
                Task { @MainActor in
                    guard let self else { return }
                    // Read live state; an old queued KVO event must not undo a
                    // newer pause or play request.
                    switch self.resources.player.timeControlStatus {
                    case .playing: self.onState?(.playing)
                    case .waitingToPlayAtSpecifiedRate: self.onState?(.waiting)
                    default: self.onState?(.paused)
                    }
                }
            },
            item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
                if let error = item.status == .failed ? item.error : nil { Task { @MainActor in self?.onFailure?(error) } }
            }
        ]
        resources.notifications = [
            NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.onEnd?() }
            },
            NotificationCenter.default.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main) { [weak self] note in
                let error = note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error ?? CocoaError(.fileReadUnknown)
                MainActor.assumeIsolated { self?.onFailure?(error) }
            }
        ]
        resources.timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.05, preferredTimescale: 1000), queue: .main) { [weak self] time in
            MainActor.assumeIsolated { if time.seconds.isFinite { self?.onPosition?(max(0, time.seconds * 1000)) } }
        }
    }
    func play() { resources.player.playImmediately(atRate: rate) }
    func setRate(_ rate: Float) { self.rate = rate; if resources.player.rate != 0 { resources.player.rate = rate } }
    func pause() { resources.player.pause() }
    func rewind(_ completion: @escaping @MainActor @Sendable (Bool) -> Void) {
        seek(toMs: 0, completion: completion)
    }
    func seek(toMs: Double, completion: @escaping @MainActor @Sendable (Bool) -> Void) {
        resources.player.seek(to: CMTime(seconds: toMs / 1000, preferredTimescale: 1_000_000), toleranceBefore: .zero, toleranceAfter: .zero) { finished in
            Task { @MainActor in completion(finished) }
        }
    }
    func close() { onState = nil; onEnd = nil; onFailure = nil; onPosition = nil; resources.close() }
}
