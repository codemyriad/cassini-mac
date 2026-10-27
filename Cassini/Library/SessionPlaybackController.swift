import AppKit
import AVFoundation
import CassiniLibrary
import CassiniPlayback
import Observation

/// The preview owns one player. Changing selection or closing the Library
/// cancels preparation and releases the previous timeline and all observers.
@MainActor @Observable
final class SessionPlaybackController {
    private(set) var isPlaying = false
    private(set) var isPreparing = false
    @ObservationIgnored private var player: AVPlayer?
    @ObservationIgnored private var key: String?
    @ObservationIgnored private var preparation: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var statusObserver: NSKeyValueObservation?
    @ObservationIgnored private var endObserver: NSObjectProtocol?

    func toggle(_ meeting: LibraryMeeting) {
        guard meeting.canPlaySession, !isPreparing else { return }
        if key == meeting.libraryKey, let player {
            if isPlaying { player.pause(); isPlaying = false }
            else { player.play(); isPlaying = true }
            return
        }
        stop()
        key = meeting.libraryKey; isPreparing = true
        let current = generation
        preparation = Task { [weak self] in
            do {
                let composition = try await SessionComposition.make(tracks: meeting.audioTracks)
                try Task.checkCancellation()
                guard let self, current == self.generation else { return }
                let item = AVPlayerItem(asset: composition)
                let player = AVPlayer(playerItem: item)
                self.player = player; self.isPreparing = false; self.preparation = nil
                self.statusObserver = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
                    let error = item.status == .failed ? item.error : nil
                    if let error { Task { @MainActor in self?.failed(error, generation: current) } }
                }
                self.endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self, current == self.generation else { return }
                        self.isPlaying = false
                        self.player?.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
                    }
                }
                player.play(); self.isPlaying = true
            } catch is CancellationError { }
            catch { self?.failed(error, generation: current) }
        }
    }
    private func failed(_ error: Error, generation current: Int) {
        guard current == generation else { return }
        stop()
        // Preserve the existing viewer's system error presentation until UX3
        // supplies its own playback error surface and shared copy.
        NSApp.presentError(error)
    }
    func stop() {
        generation += 1
        preparation?.cancel(); preparation = nil
        statusObserver?.invalidate(); statusObserver = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }; endObserver = nil
        player?.pause(); player?.replaceCurrentItem(with: nil); player = nil
        key = nil; isPlaying = false; isPreparing = false
    }
}
