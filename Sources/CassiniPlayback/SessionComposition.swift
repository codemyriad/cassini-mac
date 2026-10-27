import AVFoundation
import CassiniLibrary

/// One immutable playback timeline with a separate composition track per source.
/// No input files or capture metadata are changed. Assets load without opening
/// an audio device, so alignment can also be verified by offline asset readers.
public enum SessionComposition {
    public enum Failure: Error, Equatable { case noAudio, unknownOffset, invalidOffset, unreadableAudio }

    public static func make(tracks: [LibraryAudioTrack]) async throws -> AVComposition {
        guard !tracks.isEmpty else { throw Failure.noAudio }
        let composition = AVMutableComposition()
        for source in tracks {
            try Task.checkCancellation()
            guard let offset = source.startOffsetMs else { throw Failure.unknownOffset }
            guard offset.isFinite, offset >= 0, offset <= 86_400_000 else { throw Failure.invalidOffset }
            let asset = AVURLAsset(url: source.url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
            let audio = try await asset.loadTracks(withMediaType: .audio)
            guard let input = audio.first,
                  let output = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                throw Failure.unreadableAudio
            }
            let range = try await input.load(.timeRange)
            guard range.duration.isNumeric, range.duration > .zero else { throw Failure.unreadableAudio }
            // A nanosecond time base retains fractional millisecond offsets and
            // stays safely within Int64 across the protocol's one-day bound.
            let start = CMTime(seconds: offset / 1000, preferredTimescale: 1_000_000_000)
            try output.insertTimeRange(range, of: input, at: start)
        }
        try Task.checkCancellation()
        return composition.copy() as! AVComposition
    }
}
