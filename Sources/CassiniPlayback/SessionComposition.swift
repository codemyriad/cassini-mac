// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import CassiniLibrary

public final class SessionTimeline: @unchecked Sendable {
    public let asset: AVComposition
    let durationMs: Double
    private let storage: PlaybackStorage
    var temporaryDirectory: URL? { storage.directory }
    init(asset: AVComposition, storage: PlaybackStorage, durationMs: Double? = nil) {
        self.asset = asset; self.storage = storage
        self.durationMs = max(0,durationMs ?? asset.duration.seconds * 1000)
    }
}
/// One immutable playback timeline with a separate composition track per source.
/// No input files or capture metadata are changed. Assets load without opening
/// an audio device, so alignment can also be verified by offline asset readers.
public enum SessionComposition {
    public enum Failure: Error, Equatable, LocalizedError {
        case noAudio, unknownOffset, invalidOffset, unreadableAudio
        public var errorDescription: String? { CocoaError(.fileReadCorruptFile).localizedDescription }
    }

    public static func make(tracks: [LibraryAudioTrack]) async throws -> SessionTimeline {
        guard !tracks.isEmpty else { throw Failure.noAudio }
        let composition = AVMutableComposition()
        let storage = PlaybackStorage()
        var sources = 0
        for source in tracks {
            try Task.checkCancellation()
            guard source.url.isFileURL else { throw Failure.unreadableAudio }
            let prepared = try storage.prepare(source.url)
            if prepared.empty { continue }
            guard let offset = source.startOffsetMs else { throw Failure.unknownOffset }
            guard offset.isFinite, offset >= 0, offset <= 86_400_000 else { throw Failure.invalidOffset }
            let asset = AVURLAsset(url: prepared.url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
            let audio = try await asset.loadTracks(withMediaType: .audio)
            guard let input = audio.first,
                  let output = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                throw Failure.unreadableAudio
            }
            let range = try await input.load(.timeRange)
            guard range.duration.isNumeric else { throw Failure.unreadableAudio }
            if range.duration == .zero { composition.removeTrack(output); continue }
            // A nanosecond time base retains fractional millisecond offsets and
            // stays safely within Int64 across the protocol's one-day bound.
            let start = CMTime(seconds: offset / 1000, preferredTimescale: 1_000_000_000)
            try output.insertTimeRange(range, of: input, at: start)
            sources += 1
        }
        try Task.checkCancellation()
        guard sources > 0 else { throw Failure.noAudio }
        return SessionTimeline(asset: composition.copy() as! AVComposition, storage: storage)
    }
}
