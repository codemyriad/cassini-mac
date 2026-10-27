import Foundation

/// Reads cross-platform manifests and salvages ordinary PCM WAVs without modifying files.
public enum RecordingLoader {
    public static func decode(_ data: Data) throws -> RecordingManifest {
        guard data.count <= 1_048_576 else { throw RecordingError.invalid("Recording metadata is too large.") }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let value = try decoder.singleValueContainer().decode(String.self)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: value) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            if let date = formatter.date(from: value) { return date }
            throw RecordingError.invalid("Invalid recording creation date.")
        }
        return try decoder.decode(RecordingManifest.self, from: data)
    }

    public static func load(directory: URL) throws -> RecordingManifest {
        var result: RecordingManifest
        do {
            result = try decode(Data(contentsOf: directory.appendingPathComponent("session.json")))
        } catch {
            let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .filter { $0.lastPathComponent.hasPrefix("track-") && $0.pathExtension == "wav" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
            guard files.count <= 64 else { throw RecordingError.invalid("Too many recording tracks to recover.") }
            let tracks: [RecordingTrack] = files.compactMap { file in
                guard let info = try? wave(file, directory: directory) else { return nil }
                var track = RecordingTrack(id: file.deletingPathExtension().lastPathComponent, label: "Recovered audio", kind: "media",
                                           file: file.lastPathComponent, sampleRate: info.rate, channels: info.channels, startOffsetMs: nil, frames: info.frames)
                track.labelSource = "recovered"
                track.ended = false
                return track
            }
            guard !tracks.isEmpty else { throw RecordingError.invalid("No readable recording metadata or PCM WAV tracks were found.") }
            return RecordingManifest(version: 1, id: UUID(), createdAt: Date(), title: "Recovered recording", source: "recovered",
                state: "interrupted", problem: "Recovered audio from damaged or missing metadata. Source labels and relative start times are unavailable.", tracks: tracks, problemKind: "recovery")
        }
        guard result.version == 1, result.tracks.count <= 64 else { throw RecordingError.invalid("Unsupported recording format.") }
        for index in result.tracks.indices {
            let track = result.tracks[index]
            guard track.file == URL(fileURLWithPath: track.file).lastPathComponent, track.file.hasSuffix(".wav"),
                  (track.startOffsetMs ?? 0).isFinite, (0...86_400_000).contains(track.startOffsetMs ?? 0) else {
                throw RecordingError.invalid("Invalid recording track.")
            }
            let file = directory.appendingPathComponent(track.file)
            // Unsafe paths stay fatal; an unreadable in-folder track is recoverable independently.
            guard file.resolvingSymlinksInPath().deletingLastPathComponent() == directory.resolvingSymlinksInPath() else {
                throw RecordingError.invalid("Audio is outside the recording folder.")
            }
            do {
                let info = try wave(file, directory: directory)
                guard info.rate == track.sampleRate, info.channels == track.channels else {
                    throw RecordingError.invalid("Audio format differs from recording metadata.")
                }
                result.tracks[index].frames = info.frames
                if track.ended == true, let start = track.startOffsetMs {
                    result.tracks[index].endOffsetMs = start + Double(info.frames) / Double(info.rate) * 1000
                }
            } catch {
                result.tracks[index].frames = 0
                result.tracks[index].ended = false
                result.tracks[index].endOffsetMs = nil
                result.tracks[index].labelSource = "recovered"
                result.tracks[index].problem = "Audio unavailable: " + error.localizedDescription
                result.state = "interrupted"
                result.problemKind = "recovery"
                let note = "One or more audio tracks could not be recovered. Readable tracks remain available."
                if result.problem?.contains(note) != true { result.problem = [result.problem, note].compactMap { $0 }.joined(separator: " ") }
            }
        }
        return result
    }

    private static func wave(_ url: URL, directory: URL) throws -> (rate: Int, channels: Int, frames: UInt64) {
        let resolved = url.resolvingSymlinksInPath()
        guard resolved.deletingLastPathComponent() == directory.resolvingSymlinksInPath() else { throw RecordingError.invalid("Audio is outside the recording folder.") }
        let handle = try FileHandle(forReadingFrom: resolved); defer { try? handle.close() }
        let length = try handle.seekToEnd()
        try handle.seek(toOffset: 0)
        let header = try handle.read(upToCount: 44) ?? Data()
        // Both v1 writers produce this fixed PCM16 header. Do not guess arbitrary codecs.
        guard header.count == 44, String(data: header[0..<4], encoding: .ascii) == "RIFF",
              String(data: header[8..<16], encoding: .ascii) == "WAVEfmt ",
              String(data: header[36..<40], encoding: .ascii) == "data" else { throw RecordingError.invalid("Unsupported WAV header.") }
        func u16(_ offset: Int) -> Int { header.withUnsafeBytes { Int($0.loadUnaligned(fromByteOffset: offset, as: UInt16.self).littleEndian) } }
        func u32(_ offset: Int) -> Int { header.withUnsafeBytes { Int($0.loadUnaligned(fromByteOffset: offset, as: UInt32.self).littleEndian) } }
        let rate = u32(24), channels = u16(22)
        guard u32(16) == 16, u16(20) == 1, u16(34) == 16, (8000...192000).contains(rate), (1...2).contains(channels),
              u16(32) == channels * 2, u32(28) == rate * channels * 2 else { throw RecordingError.invalid("Unsupported PCM WAV format.") }
        // A crash can leave the header one chunk behind; complete PCM frames in the file win.
        return (rate, channels, (length - 44) / UInt64(channels * 2))
    }
}
