// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import CryptoKit
import Darwin
import CassiniKit

public enum LibraryImportOutcome: Sendable {
    case imported(LibraryMeeting)
    case duplicate(LibraryMeeting)

    public var meeting: LibraryMeeting {
        switch self {
        case .imported(let meeting), .duplicate(let meeting): return meeting
        }
    }
}

public struct LibraryImportSummary: Sendable {
    public var imported: Int = 0
    public var duplicates: Int = 0
    public var unsupported: Int = 0
    public var failed: Int = 0
    public var cancelled: Bool = false
    public var lastSelected: LibraryMeeting? = nil

    public init(imported: Int = 0, duplicates: Int = 0, unsupported: Int = 0, failed: Int = 0,
                cancelled: Bool = false, lastSelected: LibraryMeeting? = nil) {
        self.imported = imported
        self.duplicates = duplicates
        self.unsupported = unsupported
        self.failed = failed
        self.cancelled = cancelled
        self.lastSelected = lastSelected
    }

    public var hasCounts: Bool {
        imported > 0 || duplicates > 0 || unsupported > 0 || failed > 0
    }

    public func rendered(localization: LibraryLocalization = .shared,
                         language: CassiniLanguage = .system,
                         locale: Locale = .current) -> String {
        var parts: [String] = []
        if cancelled {
            parts.append(localization.text("import.cancelled", language: language, locale: locale))
        }
        if imported > 0 {
            parts.append(localization.text("import.summary.imported", ["n": String(imported)], language: language, locale: locale))
        }
        if duplicates > 0 {
            parts.append(localization.text("import.summary.duplicates", ["n": String(duplicates)], language: language, locale: locale))
        }
        if unsupported > 0 {
            parts.append(localization.text("import.summary.unsupported", ["n": String(unsupported)], language: language, locale: locale))
        }
        if failed > 0 {
            parts.append(localization.text("import.summary.failed", ["n": String(failed)], language: language, locale: locale))
        }
        return parts.joined(separator: " · ")
    }
}

/// R1.4: original bytes are private and complete before meeting.json commits the
/// import. A full-file hash identifies repeats, regardless of source filename.
public enum LibraryImport {
    public static let supportedAudioExtensions: Set<String> = ["opus", "ogg", "oga"]

    public final class BatchSession: @unchecked Sendable {
        public let root: URL
        public let additionalRoots: [URL]
        private let primaryScanner: LibraryScanner
        private var additionalScanners: [URL: LibraryScanner] = [:]
        private var knownByDigest: [String: LibraryMeeting]?

        public init(root: URL, additionalRoots: [URL] = []) {
            self.root = root
            self.additionalRoots = additionalRoots
            self.primaryScanner = LibraryScanner(root: root)
            for candidate in additionalRoots {
                additionalScanners[candidate] = LibraryScanner(root: candidate)
            }
        }

        fileprivate func duplicate(for digest: String) throws -> LibraryMeeting? {
            if knownByDigest == nil {
                var seeded: [String: LibraryMeeting] = [:]
                for candidate in ([root] + additionalRoots) where FileManager.default.fileExists(atPath: candidate.path) {
                    let scanner = candidate == root ? primaryScanner : (additionalScanners[candidate] ?? LibraryScanner(root: candidate))
                    for meeting in try scanner.scan().meetings {
                        if let sha = meeting.received?.sha256, seeded[sha] == nil {
                            seeded[sha] = meeting
                        }
                    }
                }
                knownByDigest = seeded
            }
            if let cached = knownByDigest?[digest],
               FileManager.default.fileExists(atPath: cached.folder.appendingPathComponent("meeting.json").path) {
                return cached
            }
            knownByDigest?[digest] = nil
            for candidate in ([root] + additionalRoots) where FileManager.default.fileExists(atPath: candidate.path) {
                let scanner = candidate == root ? primaryScanner : (additionalScanners[candidate] ?? LibraryScanner(root: candidate))
                if let found = try scanner.scan().meetings.first(where: { $0.received?.sha256 == digest }) {
                    knownByDigest?[digest] = found
                    return found
                }
            }
            return nil
        }

        fileprivate func recordImported(folder: URL, id: UUID, digest: String) throws -> LibraryMeeting {
            guard let meeting = try primaryScanner.scan(affected: folder).meetings.first(where: { $0.id == id }) else {
                throw POSIXError(.EINVAL)
            }
            knownByDigest?[digest] = meeting
            return meeting
        }

        fileprivate func removeRolledBack(folder: URL, digest: String?) {
            if let digest, knownByDigest?[digest]?.folder == folder {
                knownByDigest?[digest] = nil
            }
            try? FileManager.default.removeItem(at: folder)
            _ = try? primaryScanner.scan(affected: folder)
        }
    }

    public static func copy(_ source: URL, into root: URL, additionalRoots: [URL] = [], shouldCancel: () -> Bool = { false }) throws -> LibraryMeeting {
        try copyWithOutcome(source, into: root, additionalRoots: additionalRoots, shouldCancel: shouldCancel).meeting
    }

    public static func copyWithOutcome(_ source: URL, into root: URL, additionalRoots: [URL] = [],
                                       titleFallback: String? = nil, includeParentFolder: Bool = true,
                                       session: BatchSession? = nil,
                                       shouldCancel: () -> Bool = { false }) throws -> LibraryImportOutcome {
        let (input, identity) = try openRegular(source); defer { close(input) }
        guard identity.size > 0, identity.size <= Int64(UInt32.max) else { throw POSIXError(.EFBIG) }
        let read = FileHandle(fileDescriptor:input,closeOnDealloc:false)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let rootFD = open(root.path,O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard rootFD >= 0 else { throw POSIXError(.ENOENT) }; defer { close(rootFD) }
        while flock(rootFD,LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK || errno == EINTR else { throw POSIXError(.EIO) }
            if shouldCancel() { throw CancellationError() }
            Thread.sleep(forTimeInterval:0.02)
        }
        defer { flock(rootFD,LOCK_UN) }
        let id = UUID(), folder = root.appendingPathComponent("Received-" + id.uuidString.lowercased())
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        var committed = false
        defer { if !committed { try? FileManager.default.removeItem(at:folder) } }
        let original = folder.appendingPathComponent("original.opus")
        let output = open(original.path,O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,0o600)
        guard output >= 0 else { throw POSIXError(.EIO) }
        let write = FileHandle(fileDescriptor:output,closeOnDealloc:true); defer { try? write.close() }
        var hash = SHA256(), copied: Int64 = 0
        while let data = try read.read(upToCount:1024 * 1024), !data.isEmpty {
            if shouldCancel() { throw CancellationError() }
            copied += Int64(data.count); guard copied <= identity.size else { throw POSIXError(.EINVAL) }
            hash.update(data:data); try write.write(contentsOf:data)
        }
        var after = stat()
        guard copied == identity.size, fstat(input,&after) == 0, FileKey(after) == identity else { throw POSIXError(.EINVAL) }
        try write.synchronize()
        let digest = hash.finalize().map { String(format:"%02x",$0) }.joined()
        let data = try Data(contentsOf:original,options:.mappedIfSafe)
        let file = try CassiniReader.read(data)
        guard case .success? = file.audioDigest else { throw MetadataError.invalid }
        if let session {
            if let duplicate = try session.duplicate(for: digest) { return .duplicate(duplicate) }
        } else {
            for candidate in [root] + additionalRoots where FileManager.default.fileExists(atPath:candidate.path) {
                if let duplicate = try LibraryScanner(root:candidate).scan().meetings.first(where: { $0.received?.sha256 == digest }) {
                    return .duplicate(duplicate)
                }
            }
        }
        if shouldCancel() { throw CancellationError() }
        let trusted = [.ok,.plainAudio].contains(file.state)
        let importedNotes = Self.importedNotes(trusted ? file.manifest?.raw["x"]?["gocassini.com"]?["notes"] : nil)
        let fallbackStem = titleFallback ?? source.deletingPathExtension().lastPathComponent
        let title = [trusted ? file.manifest?.meeting.title : nil,trusted ? file.tags?["TITLE"] : nil,fallbackStem]
            .compactMap { $0?.trimmingCharacters(in:.whitespacesAndNewlines) }.first { !$0.isEmpty }
        if shouldCancel() { throw CancellationError() }
        try MeetingMetadataWriter(directory:folder,id:id).transaction { metadata in
            var received: [String:Any] = ["originalName":"original.opus","sha256":digest,"importedAtMs":Int64(Date().timeIntervalSince1970 * 1000)]
            if includeParentFolder {
                let parent = String(String.UnicodeScalarView(source.deletingLastPathComponent().lastPathComponent.unicodeScalars.prefix(255)))
                if safeBasename(parent) { received["originalFolderName"] = parent }
            }
            metadata["received"] = received
            metadata["notes"] = importedNotes
            if trusted, let route = Self.importedOthersRoute(file.manifest?.raw["x"]?["codemyriad.io"]) {
                metadata["recordingDetails"] = ["othersRoute":route]
            }
            if let title { metadata["title"] = String(String.UnicodeScalarView(title.unicodeScalars.prefix(500))) }
            if let transcript = Self.importedTranscript(file) { metadata["transcript"] = transcript }
        }
        let meeting: LibraryMeeting
        if let session {
            meeting = try session.recordImported(folder: folder, id: id, digest: digest)
        } else {
            guard let scanned = try LibraryScanner(root:root).scan().meetings.first(where: { $0.id == id }) else { throw POSIXError(.EINVAL) }
            meeting = scanned
        }
        committed = true
        return .imported(meeting)
    }

    internal static func rollbackImported(folder: URL, digest: String?, session: BatchSession?) {
        if let session {
            session.removeRolledBack(folder: folder, digest: digest)
        } else {
            try? FileManager.default.removeItem(at: folder)
        }
    }

    /// D74 immutable routing provenance travels with the recording, including future
    /// source/reason/site strings. The original namespace remains authoritative for
    /// re-export; this local copy lets Details work after import without a live tab.
    public static func importedOthersRoute(_ namespace: JSON?) -> [String:Any]? {
        guard namespace?["schema"]?.int == 1, let route = namespace?["meeting"]?["recordingDetails"]?["othersRoute"], route.object != nil else { return nil }
        for key in ["source","reason","site"] {
            guard let text = route[key]?.string, !text.isEmpty, text.unicodeScalars.count <= 200, text.utf8.count <= 800 else { return nil }
        }
        guard let bytes = try? route.encoded(maximumBytes:MeetingMetadataLimit.bytes),
              let copy = try? JSONSerialization.jsonObject(with:bytes) as? [String:Any] else { return nil }
        return copy
    }

    /// The notes import keeps from a file's x["gocassini.com"].notes: each valid note's atMs
    /// and text, in order; invalid notes and other members are dropped.
    public static func importedNotes(_ notes: JSON?) -> [[String:Any]] {
        (notes?.array ?? []).compactMap { note in
            guard let time = note["atMs"]?.int, time >= 0, time <= AppMetadata.safe,
                  let text = note["text"]?.string, text.unicodeScalars.count <= 100000 else { return nil }
            return ["atMs":time,"text":text]
        }
    }
    /// The transcript state import stores for `file`; nil keeps the default (none, no reference).
    public static func importedTranscript(_ file: CassiniFile) -> [String:Any]? {
        let trusted = [.ok,.plainAudio].contains(file.state)
        let selected = trusted ? file.defaultTranscript : nil
        let timed = file.transcripts.filter { $0.entry.format == "cassini.words.v1" }
        if trusted && !timed.isEmpty && timed.allSatisfy({ $0.load.transcript?.items.isEmpty == true }) {
            // D12: a valid empty word-timed body is ready to write down.
            return ["status":"none","reference":NSNull()]
        }
        if let selected, selected.load.transcript != nil {
            return ["status":"done","reference":["kind":"embedded","file":"original.opus","transcriptId":selected.entry.id]]
        }
        return !trusted || selected != nil ? ["status":"damaged","reference":NSNull()] : nil
    }
}
