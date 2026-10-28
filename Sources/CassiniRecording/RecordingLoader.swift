// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Darwin

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
            let input = try regular(directory.appendingPathComponent("session.json"),maximum:1_048_576)
            defer { try? input.close() }
            result = try decode(input.read(upToCount:1_048_577) ?? Data())
            guard result.version == 1, result.tracks.count <= 64 else { throw RecordingError.invalid("Unsupported recording format.") }
            if directory.lastPathComponent.hasPrefix("Recording-"), let id = UUID(uuidString:String(directory.lastPathComponent.dropFirst(10))), id != result.id {
                throw RecordingError.invalid("Recording identity differs from its folder.")
            }
        } catch {
            let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .filter { $0.lastPathComponent.hasPrefix("track-") && $0.pathExtension == "wav" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
            guard files.count <= 64 else { throw RecordingError.invalid("Too many recording tracks to recover.") }
            let tracks: [RecordingTrack] = files.compactMap { file in
                guard let info = try? wave(file, directory: directory) else { return nil }
                return RecordingTrack(id: String(file.deletingPathExtension().lastPathComponent.dropFirst("track-".count)), label: "Recovered audio", kind: "media",
                                      file: file.lastPathComponent, sampleRate: info.rate, channels: info.channels, startOffsetMs: nil, frames: info.frames)
            }
            guard !tracks.isEmpty else { throw RecordingError.invalid("No readable recording metadata or PCM WAV tracks were found.") }
            return RecordingManifest(version: 1, id: UUID(), createdAt: Date(), title: "Recovered recording", source: "recovered",
                state: "interrupted", problem: "Recovered audio from damaged or missing metadata. Source labels and relative start times are unavailable.", tracks: tracks, problemKind: "recovery")
        }
        let originalCount = result.tracks.count
        result.tracks = result.tracks.compactMap { input in
            var track = input
            guard track.file == URL(fileURLWithPath:track.file).lastPathComponent, track.file.hasSuffix(".wav"),
                  (track.startOffsetMs ?? 0).isFinite, (0...86_400_000).contains(track.startOffsetMs ?? 0),
                  let info = try? wave(directory.appendingPathComponent(track.file),directory:directory),
                  info.rate == track.sampleRate, info.channels == track.channels else { return nil }
            track.frames = info.frames; return track
        }
        guard originalCount == 0 || !result.tracks.isEmpty else { throw RecordingError.invalid("No readable recording tracks were found.") }
        return result
    }

    private static func wave(_ url: URL, directory: URL) throws -> (rate: Int, channels: Int, frames: UInt64) {
        guard url.standardizedFileURL.deletingLastPathComponent().path == directory.standardizedFileURL.path else { throw RecordingError.invalid("Audio is outside the recording folder.") }
        let handle = try regular(url); defer { try? handle.close() }
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
    private static func regular(_ url: URL, maximum: UInt64 = UInt64(UInt32.max) + 8) throws -> FileHandle {
        let fd = open(url.path,O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw RecordingError.invalid("Unreadable recording file.") }
        var info = stat()
        guard fstat(fd,&info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size >= 0, UInt64(info.st_size) <= maximum else {
            close(fd); throw RecordingError.invalid("Invalid recording file.")
        }
        return FileHandle(fileDescriptor:fd,closeOnDealloc:true)
    }

}
