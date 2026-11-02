// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Darwin
import CassiniKit

/// App-owned metadata only. Capture session.json and audio remain producer-owned.
/// Serial transactions preserve fields and reject unsupported/invalid metadata.
public final class MeetingMetadataWriter: @unchecked Sendable {
    /// The meeting.json a folder implies before its first metadata write.
    public static func defaultDocument(id: UUID) -> [String: Any] {
        ["version": 1, "revision": 0, "id": id.uuidString.lowercased(), "title": NSNull(),
         "titleSource": "meeting-window", "notes": [], "speakers": [],
         "transcript": ["status": "none", "reference": NSNull()], "etaMinutes": NSNull(),
         "error": NSNull(), "quoteOverride": NSNull(), "received": NSNull()]
    }
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
    /// The edited document, keeping the original's member order and the original text of
    /// every value the edit left equal (so 0.1 stays 0.1, -0 stays -0, 1e300 stays 1e300).
    static func preserving(_ original: JSON, edited: JSON) -> JSON {
        switch (original, edited) {
        case (.object(let old), .object(let new)):
            var result: [(String, JSON)] = []
            for (key, value) in old { if let replacement = new.first(where: { $0.0 == key })?.1 { result.append((key, preserving(value, edited: replacement))) } }
            for (key, value) in new where !old.contains(where: { $0.0 == key }) { result.append((key, value)) }
            return .object(result)
        case (.array(let old), .array(let new)):
            return .array(new.indices.map { $0 < old.count ? preserving(old[$0], edited: new[$0]) : new[$0] })
        case (.number(let old), .number(let new)):
            return Decimal(string: old) == Decimal(string: new) || Double(old) == Double(new) ? original : edited
        default:
            return original == edited ? original : edited
        }
    }
    /// An edit that changes nothing writes nothing and keeps the revision.
    public func transaction(skippingUnchanged: Bool, _ edit: (inout [String: Any]) throws -> Void) throws {
        try perform(createOnly: false, skippingUnchanged: skippingUnchanged, edit)
    }
    private func perform(createOnly: Bool, skippingUnchanged: Bool = false, _ edit: (inout [String: Any]) throws -> Void) throws {
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
        var original: JSON?
        if input >= 0 {
            defer { Darwin.close(input) }
            var info = stat()
            guard fstat(input, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size <= MeetingMetadataLimit.bytes else { throw MetadataError.invalid }
            let data = try regularData(input, limit: MeetingMetadataLimit.bytes)
            let metadata = try AppMetadata.parse(data)
            try metadata.validate(id: id, received: directory.lastPathComponent.hasPrefix("Received-"))
            if createOnly { return }
            guard metadata.revision < AppMetadata.safe else { throw MetadataError.invalid }
            document = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            original = try JSONParser.parse(data)
            if skippingUnchanged {
                var probe = document
                try edit(&probe)
                if (probe as NSDictionary).isEqual(to: document) { return }
            }
            document["revision"] = metadata.revision + 1
        } else {
            guard errno == ENOENT else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            document = Self.defaultDocument(id: id)
        }
        try edit(&document)
        let edited = try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys, .prettyPrinted])
        // D47/D56: everything the edit did not change is written back verbatim, including
        // members this app does not know (speakers[].voiceSource…) and their number literals.
        let data = try original.map { try Self.preserving($0, edited: JSONParser.parse(edited)).encoded(maximumBytes: MeetingMetadataLimit.bytes) } ?? edited
        guard data.count <= MeetingMetadataLimit.bytes else { throw POSIXError(.EFBIG) }
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
