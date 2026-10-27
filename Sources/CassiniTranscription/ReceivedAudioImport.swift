// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import CryptoKit
import Darwin
import CassiniLibrary

/// The explicit Write it down action on an opened Opus makes a private Library
/// copy. The external original and its embedded annotations are never modified.
public enum ReceivedAudioImport {
    public static func copy(_ source: URL, into root: URL) throws -> LibraryMeeting {
        let input = open(source.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard input >= 0 else { throw TranscriptionFailure.audioFormat }
        var info = stat()
        guard fstat(input, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size > 0, info.st_size <= Int64(UInt32.max) else { close(input); throw TranscriptionFailure.audioFormat }
        let read = FileHandle(fileDescriptor: input, closeOnDealloc: true); defer { try? read.close() }
        let id = UUID(), folder = root.appendingPathComponent("Received-" + id.uuidString.lowercased())
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
            let original = folder.appendingPathComponent("original.opus")
            guard FileManager.default.createFile(atPath: original.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw TranscriptionFailure.invalidMeeting }
            let output = try FileHandle(forWritingTo: original); defer { try? output.close() }
            var hash = SHA256(), copied: Int64 = 0
            while let data = try read.read(upToCount: 1024 * 1024), !data.isEmpty {
                copied += Int64(data.count); guard copied <= info.st_size else { throw TranscriptionFailure.audioFormat }
                hash.update(data: data); try output.write(contentsOf: data)
            }
            guard copied == info.st_size else { throw TranscriptionFailure.audioFormat }
            try output.synchronize()
            let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
            try MeetingMetadataWriter(directory: folder, id: id).transaction { metadata in
                metadata["received"] = ["originalName":"original.opus", "originalFolderName":NSNull(), "sha256":digest, "importedAtMs":Int64(Date().timeIntervalSince1970 * 1000)]
                metadata["title"] = source.deletingPathExtension().lastPathComponent
                metadata["titleSource"] = "meeting-window"
            }
            guard let meeting = try LibraryScanner(root: root).scan().meetings.first(where: { $0.id == id }), meeting.canWriteDown else { throw TranscriptionFailure.audioFormat }
            return meeting
        } catch { try? FileManager.default.removeItem(at: folder); throw error }
    }
}
