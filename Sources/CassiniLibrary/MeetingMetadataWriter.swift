// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Darwin

/// App-owned metadata only. Capture session.json and audio remain producer-owned.
/// Serial transactions preserve fields and reject unsupported/invalid metadata.
public final class MeetingMetadataWriter: @unchecked Sendable {
    private let lock = NSLock()
    public let directory: URL
    public let id: UUID
    public init(directory: URL, id: UUID) throws {
        guard LibraryScanner.identity(directory.lastPathComponent)?.0 == id else { throw MetadataError.invalid }
        self.directory = directory; self.id = id
    }
    public func createIfNeeded() throws {
        try perform(createOnly: true) { _ in }
    }
    public func transaction(_ edit: (inout [String: Any]) throws -> Void) throws {
        try perform(createOnly: false, edit)
    }
    private func perform(createOnly: Bool, _ edit: (inout [String: Any]) throws -> Void) throws {
        lock.lock(); defer { lock.unlock() }
        let fd = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw POSIXError(.ENOENT) }; defer { Darwin.close(fd) }
        while flock(fd, LOCK_EX) != 0 {
            if errno == EINTR { continue }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { flock(fd, LOCK_UN) }
        let input = openat(fd, "meeting.json", O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        var document: [String: Any]
        if input >= 0 {
            defer { Darwin.close(input) }
            var info = stat()
            guard fstat(input, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size <= 1_048_576 else { throw MetadataError.invalid }
            let data = try regularData(input, limit: 1_048_576)
            let metadata = try AppMetadata.parse(data)
            try metadata.validate(id: id, received: directory.lastPathComponent.hasPrefix("Received-"))
            if createOnly { return }
            guard metadata.revision < AppMetadata.safe else { throw MetadataError.invalid }
            document = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            document["revision"] = metadata.revision + 1
        } else {
            guard errno == ENOENT else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            document = ["version": 1, "revision": 0, "id": id.uuidString.lowercased(), "title": NSNull(),
                "titleSource": "meeting-window", "notes": [], "speakers": [],
                "transcript": ["status": "none", "reference": NSNull()], "etaMinutes": NSNull(),
                "error": NSNull(), "quoteOverride": NSNull(), "received": NSNull()]
        }
        try edit(&document)
        let data = try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys, .prettyPrinted])
        guard data.count <= 1_048_576 else { throw POSIXError(.EFBIG) }
        let metadata = try AppMetadata.parse(data)
        try metadata.validate(id: id, received: directory.lastPathComponent.hasPrefix("Received-"))
        let temporary = ".meeting-\(UUID().uuidString).tmp"
        let output = openat(fd, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard output >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { Darwin.close(output); unlinkat(fd, temporary, 0) }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let n = Darwin.write(output, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                offset += n
            }
        }
        guard fsync(output) == 0, renameat(fd, temporary, fd, "meeting.json") == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        if fsync(fd) != 0 && errno != EINVAL { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
}
