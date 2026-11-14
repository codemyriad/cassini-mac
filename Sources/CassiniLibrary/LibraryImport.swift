// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import CryptoKit
import Darwin
import CassiniKit

public enum LibraryImportOutcome: Sendable {
    case imported(LibraryMeeting)
    case duplicate(LibraryMeeting)

    /// Only a newly committed copy announces an import; reopening a duplicate is silent.
    public func confirmation(language: CassiniLanguage, locale: Locale) -> String? {
        guard case .imported(let meeting) = self else { return nil }
        if let folder = meeting.received?.originalFolderName, !folder.isEmpty {
            return LibraryLocalization.shared.text("received.importedToast", ["folder": folder], language: language, locale: locale)
        }
        return LibraryLocalization.shared.text("received.importedToast.noFolder", language: language, locale: locale)
    }

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

/// Independent transfer lanes rendered by `TransferStatusBanner` so concurrent import and export
/// operations never hide one another's progress, Cancel action, or completion notice.
public struct TransferBannerPresentation: Equatable, Sendable {
    public struct ImportProgress: Equatable, Sendable {
        public let done: Int
        public let total: Int
        public init(done: Int, total: Int) { self.done = done; self.total = total }
    }

    public struct ImportNotice: Equatable, Sendable {
        public let id: UUID
        public let message: String
        public let isWarning: Bool
        public let autoDismiss: Bool
        public init(id: UUID, message: String, isWarning: Bool, autoDismiss: Bool) {
            self.id = id
            self.message = message
            self.isWarning = isWarning
            self.autoDismiss = autoDismiss
        }
    }

    public struct BulkExportProgress: Equatable, Sendable {
        public let done: Int
        public let total: Int
        public init(done: Int, total: Int) { self.done = done; self.total = total }
    }

    public struct BulkExportReceipt: Equatable, Sendable {
        public let id: UUID
        public let count: Int
        public init(id: UUID, count: Int) { self.id = id; self.count = count }
    }

    public struct SingleExportReceipt: Equatable, Sendable {
        public let id: UUID
        public let title: String
        public let folderName: String
        public init(id: UUID, title: String, folderName: String) {
            self.id = id
            self.title = title
            self.folderName = folderName
        }
    }

    public enum Card: Equatable, Sendable, Identifiable {
        case importProgress(done: Int, total: Int)
        case importNotice(ImportNotice)
        case bulkExportProgress(done: Int, total: Int)
        case bulkExportReceipt(BulkExportReceipt)
        case singleExportReceipt(SingleExportReceipt)

        public var id: String {
            switch self {
            case .importProgress: return "import-progress"
            case .importNotice(let notice): return "import-notice-\(notice.id.uuidString)"
            case .bulkExportProgress: return "export-zip-progress"
            case .bulkExportReceipt(let receipt): return "export-zip-receipt-\(receipt.id.uuidString)"
            case .singleExportReceipt(let receipt): return "export-single-receipt-\(receipt.id.uuidString)"
            }
        }

        public var primaryAccessibilityID: String {
            switch self {
            case .importProgress: return "import-progress"
            case .importNotice(let notice): return notice.isWarning ? "import-warning" : "import-summary"
            case .bulkExportProgress: return "export-zip-progress"
            case .bulkExportReceipt: return "export-zip-success"
            case .singleExportReceipt: return "export-success"
            }
        }

        public var actionAccessibilityID: String {
            switch self {
            case .importProgress: return "import-cancel"
            case .importNotice: return "import-notice-done"
            case .bulkExportProgress: return "export-zip-cancel"
            case .bulkExportReceipt: return "export-zip-show"
            case .singleExportReceipt: return "export-show"
            }
        }
    }

    public let cards: [Card]

    public init(
        importProgress: ImportProgress? = nil,
        importNotice: ImportNotice? = nil,
        bulkExportProgress: BulkExportProgress? = nil,
        bulkExportReceipt: BulkExportReceipt? = nil,
        singleExportReceipt: SingleExportReceipt? = nil
    ) {
        var resolved: [Card] = []
        if let importProgress {
            resolved.append(.importProgress(done: importProgress.done, total: importProgress.total))
        } else if let importNotice {
            resolved.append(.importNotice(importNotice))
        }
        if let bulkExportProgress {
            resolved.append(.bulkExportProgress(done: bulkExportProgress.done, total: bulkExportProgress.total))
        } else if let bulkExportReceipt {
            resolved.append(.bulkExportReceipt(bulkExportReceipt))
        } else if let singleExportReceipt {
            resolved.append(.singleExportReceipt(singleExportReceipt))
        }
        self.cards = resolved
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
            if let cached = knownByDigest?[digest] {
                if FileManager.default.fileExists(atPath: cached.folder.appendingPathComponent("meeting.json").path) {
                    return cached
                }
                knownByDigest?[digest] = nil
            }
            return nil
        }

        fileprivate func recordImported(folder: URL, id: UUID, digest: String) throws -> LibraryMeeting {
            let meeting = try LibraryImport.readSingleImportedMeeting(root: root, folder: folder, id: id)
            knownByDigest?[digest] = meeting
            return meeting
        }
    }

    internal struct ProvisionalImport {
        let id: UUID
        let folderName: String
        let digest: String
    }

    internal enum ArchiveStageOutcome {
        case staged(ProvisionalImport)
        case existingDuplicate(LibraryMeeting)
        case provisionalDuplicate(Int)
    }

    fileprivate static func readSingleImportedMeeting(root: URL, folder: URL, id: UUID) throws -> LibraryMeeting {
        let resolvedRoot = try physicalURL(root)
        let canonicalFolder = URL(fileURLWithPath: resolvedRoot.path + "/" + folder.lastPathComponent, isDirectory: false)
        guard let meeting = LibraryScanner(root: resolvedRoot).meeting(at: canonicalFolder), meeting.id == id else {
            throw POSIXError(.EINVAL)
        }
        return meeting
    }

    /// Stages a validated archive audio entry into an unpublished hidden directory inside `root`
    /// so `LibraryScanner`, watchers, and UI cannot discover or edit it until every archive member passes runtime limits.
    internal static func stageArchiveMember(
        _ source: URL,
        into root: URL,
        provisionalRoot: inout URL?,
        titleFallback: String,
        session: BatchSession,
        provisionalIndexByDigest: [String: Int],
        shouldCancel: () -> Bool
    ) throws -> ArchiveStageOutcome {
        let (input, identity) = try openRegular(source); defer { close(input) }
        guard identity.size > 0, identity.size <= Int64(UInt32.max) else { throw POSIXError(.EFBIG) }
        let data = try Data(contentsOf: source, options: .mappedIfSafe)
        guard Int64(data.count) == identity.size else { throw POSIXError(.EINVAL) }
        var after = stat()
        guard fstat(input, &after) == 0, FileKey(after) == identity else { throw POSIXError(.EINVAL) }
        if shouldCancel() { throw CancellationError() }

        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let file = try CassiniReader.read(data)
        guard case .success? = file.audioDigest else { throw MetadataError.invalid }

        if let existing = try session.duplicate(for: digest) {
            return .existingDuplicate(existing)
        }
        if let earlierIndex = provisionalIndexByDigest[digest] {
            return .provisionalDuplicate(earlierIndex)
        }
        if shouldCancel() { throw CancellationError() }

        let stageDir: URL
        if let existingStage = provisionalRoot {
            stageDir = existingStage
        } else {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let created = root.appendingPathComponent(".cassini-zip-import-" + UUID().uuidString.lowercased())
            try FileManager.default.createDirectory(at: created, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            provisionalRoot = created
            stageDir = created
        }

        let id = UUID()
        let folderName = "Received-" + id.uuidString.lowercased()
        let folder = stageDir.appendingPathComponent(folderName)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        var staged = false
        defer { if !staged { try? FileManager.default.removeItem(at: folder) } }

        let original = folder.appendingPathComponent("original.opus")
        let output = open(original.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard output >= 0 else { throw POSIXError(.EIO) }
        do {
            let write = FileHandle(fileDescriptor: output, closeOnDealloc: true)
            defer { try? write.close() }
            try write.write(contentsOf: data)
            try write.synchronize()
        }

        if shouldCancel() { throw CancellationError() }
        let trusted = [.ok, .plainAudio].contains(file.state)
        let importedNotes = Self.importedNotes(trusted ? file.manifest?.raw["x"]?["gocassini.com"]?["notes"] : nil)
        let title = [trusted ? file.manifest?.meeting.title : nil, trusted ? file.tags?["TITLE"] : nil, titleFallback]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty }
        if shouldCancel() { throw CancellationError() }

        try MeetingMetadataWriter(directory: folder, id: id).transaction { metadata in
            metadata["received"] = [
                "originalName": "original.opus",
                "sha256": digest,
                "importedAtMs": Int64(Date().timeIntervalSince1970 * 1000),
            ] as [String: Any]
            metadata["notes"] = importedNotes
            if trusted, let route = Self.importedOthersRoute(file.manifest?.raw["x"]?["codemyriad.io"]) {
                metadata["recordingDetails"] = ["othersRoute": route]
            }
            if let title { metadata["title"] = String(String.UnicodeScalarView(title.unicodeScalars.prefix(500))) }
            if let transcript = Self.importedTranscript(file) { metadata["transcript"] = transcript }
        }
        staged = true
        return .staged(ProvisionalImport(id: id, folderName: folderName, digest: digest))
    }

    /// Atomically publishes staged provisional archive meetings into `root` once all archive members pass validation.
    internal static func publishArchiveMembers(
        _ provisionals: [ProvisionalImport],
        from provisionalRoot: URL,
        into root: URL,
        session: BatchSession,
        onPublished: (LibraryMeeting, _ isDuplicate: Bool) -> Void = { _, _ in },
        shouldCancel: () -> Bool
    ) throws -> [(meeting: LibraryMeeting, isDuplicate: Bool)] {
        guard !provisionals.isEmpty else { return [] }
        if shouldCancel() { throw CancellationError() }
        let rootFD = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard rootFD >= 0 else { throw POSIXError(.ENOENT) }
        defer { close(rootFD) }
        while flock(rootFD, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK || errno == EINTR else { throw POSIXError(.EIO) }
            if shouldCancel() { throw CancellationError() }
            Thread.sleep(forTimeInterval: 0.02)
        }
        defer { flock(rootFD, LOCK_UN) }

        let stageFD = open(provisionalRoot.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard stageFD >= 0 else { throw POSIXError(.ENOENT) }
        defer { close(stageFD) }

        var anyRenamed = false
        defer {
            if anyRenamed {
                _ = fsync(rootFD)
            }
        }

        var published: [(meeting: LibraryMeeting, isDuplicate: Bool)] = []
        published.reserveCapacity(provisionals.count)
        for prov in provisionals {
            if shouldCancel() { throw CancellationError() }
            if let existing = try session.duplicate(for: prov.digest) {
                published.append((existing, true))
                onPublished(existing, true)
                continue
            }
            guard renameatx_np(stageFD, prov.folderName, rootFD, prov.folderName, UInt32(RENAME_EXCL)) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            anyRenamed = true
            let finalFolder = root.appendingPathComponent(prov.folderName)
            let meeting = try session.recordImported(folder: finalFolder, id: prov.id, digest: prov.digest)
            published.append((meeting, false))
            onPublished(meeting, false)
        }
        return published
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
            meeting = try readSingleImportedMeeting(root: root, folder: folder, id: id)
        }
        committed = true
        return .imported(meeting)
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
