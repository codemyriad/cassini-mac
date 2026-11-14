// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Darwin
import CryptoKit
import CassiniKit

public enum TrashIdentity: Sendable, Equatable, Hashable {
    case session(String)
    case sha(String)

    public var key: String {
        switch self {
        case .session(let id): return id
        case .sha(let hex): return "sha:" + hex
        }
    }

    var jsonObject: [String: Any] {
        switch self {
        case .session(let id): return ["session": id]
        case .sha(let hex): return ["sha": hex]
        }
    }

    static func fromJSON(_ raw: Any?) -> TrashIdentity? {
        guard let dict = raw as? [String: Any] else { return nil }
        if let s = dict["session"] as? String, !s.isEmpty { return .session(s) }
        if let sha = dict["sha"] as? String, !sha.isEmpty { return .sha(sha) }
        return nil
    }
}

public struct TrashPublished: Sendable, Equatable {
    public let name: String
    public let namePrefix: String?
    public let title: String

    public init(name: String, namePrefix: String?, title: String) {
        self.name = name
        self.namePrefix = namePrefix
        self.title = title
    }

    var jsonObject: [String: Any] {
        [
            "name": name,
            "namePrefix": namePrefix as Any? ?? NSNull(),
            "title": title,
        ]
    }

    static func fromJSON(_ raw: Any?) -> TrashPublished? {
        guard let dict = raw as? [String: Any],
              let name = dict["name"] as? String,
              let title = dict["title"] as? String else { return nil }
        let prefix = dict["namePrefix"] as? String
        return TrashPublished(name: name, namePrefix: prefix, title: title)
    }
}

public struct TrashSession: Sendable, Equatable {
    public let path: String
    public let layout: String

    public init(path: String, layout: String) {
        self.path = path
        self.layout = layout
    }

    public var folderName: String {
        path.split(separator: "/").last.map(String.init) ?? path
    }

    var jsonObject: [String: Any] {
        ["layout": layout, "path": path]
    }

    static func fromJSON(_ raw: Any?) -> TrashSession? {
        guard let dict = raw as? [String: Any],
              let path = dict["path"] as? String,
              let layout = dict["layout"] as? String else { return nil }
        return TrashSession(path: path, layout: layout)
    }
}

public struct TrashDisplay: Sendable, Equatable {
    public let title: String
    public let recordedAtUtc: String?
    public let durationMs: Int?

    public init(title: String, recordedAtUtc: String?, durationMs: Int?) {
        self.title = title
        self.recordedAtUtc = recordedAtUtc
        self.durationMs = durationMs
    }

    var jsonObject: [String: Any] {
        [
            "durationMs": durationMs as Any? ?? NSNull(),
            "recordedAtUtc": recordedAtUtc as Any? ?? NSNull(),
            "title": title,
        ]
    }

    static func fromJSON(_ raw: Any?) -> TrashDisplay? {
        guard let dict = raw as? [String: Any],
              let title = dict["title"] as? String else { return nil }
        let recordedAtUtc = dict["recordedAtUtc"] as? String
        let durationMs = (dict["durationMs"] as? NSNumber)?.intValue
        return TrashDisplay(title: title, recordedAtUtc: recordedAtUtc, durationMs: durationMs)
    }
}

public struct TrashEntry: Sendable, Equatable, Identifiable {
    public var id: String { "\(root.path)::\(entryId)" }
    public let root: URL
    public let entryId: String
    public let deletedAtUtc: String
    public let identity: TrashIdentity
    public let published: TrashPublished?
    public let session: TrashSession?
    public let display: TrashDisplay

    public init(
        root: URL,
        entryId: String,
        deletedAtUtc: String,
        identity: TrashIdentity,
        published: TrashPublished?,
        session: TrashSession?,
        display: TrashDisplay
    ) {
        self.root = root
        self.entryId = entryId
        self.deletedAtUtc = deletedAtUtc
        self.identity = identity
        self.published = published
        self.session = session
        self.display = display
    }

    public var deletedAt: Date? {
        (try? LibraryNames.parseUTC(deletedAtUtc)) ?? MeetingTime.parseInstant(deletedAtUtc)
    }

    public var recordedAt: Date? {
        guard let recordedAtUtc else { return nil }
        return (try? LibraryNames.parseUTC(recordedAtUtc)) ?? MeetingTime.parseInstant(recordedAtUtc)
    }

    private var recordedAtUtc: String? { display.recordedAtUtc }
}

public struct TrashDaysLeft: Sendable, Equatable {
    public let daysLeft: Int
    public let expired: Bool

    public init(daysLeft: Int, expired: Bool) {
        self.daysLeft = daysLeft
        self.expired = expired
    }
}

public struct TrashRequest: Sendable {
    public var entryId: String
    public var deletedAtUtc: String
    public var title: String
    public var recordedAtUtc: String?
    public var durationMs: Int?
    public var published: String?
    public var session: String?
    public var namePrefix: String?
    public var activeLease: Bool

    public init(
        entryId: String = UUID().uuidString.lowercased(),
        deletedAtUtc: String,
        title: String,
        recordedAtUtc: String? = nil,
        durationMs: Int? = nil,
        published: String? = nil,
        session: String? = nil,
        namePrefix: String? = nil,
        activeLease: Bool = false
    ) {
        self.entryId = entryId
        self.deletedAtUtc = deletedAtUtc
        self.title = title
        self.recordedAtUtc = recordedAtUtc
        self.durationMs = durationMs
        self.published = published
        self.session = session
        self.namePrefix = namePrefix
        self.activeLease = activeLease
    }
}

public struct TrashStep: Sendable, Equatable {
    public var action: String
    public var path: String?
    public var content: String?
    public var from: String?
    public var to: String?
    public var nameFrom: String?

    public init(
        action: String,
        path: String? = nil,
        content: String? = nil,
        from: String? = nil,
        to: String? = nil,
        nameFrom: String? = nil
    ) {
        self.action = action
        self.path = path
        self.content = content
        self.from = from
        self.to = to
        self.nameFrom = nameFrom
    }

    var jsonObject: [String: Any] {
        var obj: [String: Any] = ["do": action]
        if let path { obj["path"] = path }
        if let content { obj["content"] = content }
        if let from { obj["from"] = from }
        if let to { obj["to"] = to }
        if let nameFrom { obj["nameFrom"] = nameFrom }
        return obj
    }

    static func fromJSON(_ raw: [String: Any]) -> TrashStep? {
        guard let action = raw["do"] as? String else { return nil }
        return TrashStep(
            action: action,
            path: raw["path"] as? String,
            content: raw["content"] as? String,
            from: raw["from"] as? String,
            to: raw["to"] as? String,
            nameFrom: raw["nameFrom"] as? String
        )
    }
}

public enum TrashError: Error, Equatable {
    case refused(String)
    case conflict(String)
}

public struct PublishedProbeResult: Sendable {
    public let identity: TrashIdentity
    public let namePrefix: String?
    public let title: String?
    public let recordedAtUtc: String?
    public let durationMs: Int?

    public init(
        identity: TrashIdentity,
        namePrefix: String? = nil,
        title: String? = nil,
        recordedAtUtc: String? = nil,
        durationMs: Int? = nil
    ) {
        self.identity = identity
        self.namePrefix = namePrefix
        self.title = title
        self.recordedAtUtc = recordedAtUtc
        self.durationMs = durationMs
    }
}

/// S-12 §7.1: journaled in-app Recently Deleted storage in `<Library>/.cassini/trash/`.
/// Coordinates with `library.lock`, import publication, metadata edits, and speech workers;
/// never calls `FileManager.trashItem` or touches the system Trash.
public enum LibraryTrash {
    public static let journalDirectory = ".cassini/journal"
    public static let sessionsDirectory = ".cassini/sessions"
    public static let trashDirectory = ".cassini/trash"
    public static let libraryLockPath = ".cassini/library.lock"
    public static let entryFileName = "entry.json"
    public static let publishedEntryFileName = "meeting.opus"
    public static let retentionDays = 30
    public static let maxSuffixRetries = 99

    public typealias IdentityProbe = @Sendable (URL) throws -> PublishedProbeResult

    private static let utcCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    public static func formatUTC(_ date: Date) -> String {
        let floored = Date(timeIntervalSince1970: floor(date.timeIntervalSince1970))
        let c = utcCalendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: floored)
        return String(
            format: "%04d-%02d-%02dT%02d:%02d:%02dZ",
            c.year!, c.month!, c.day!, c.hour!, c.minute!, c.second!
        )
    }

    // MARK: - Retention calculation (S-12 §7.1)

    public static func daysLeft(deletedAtUtc: String, nowUtc: String) throws -> TrashDaysLeft {
        let deleted = try LibraryNames.parseUTC(deletedAtUtc)
        let now = try LibraryNames.parseUTC(nowUtc)
        return daysLeft(deletedAt: deleted, now: now)
    }

    public static func daysLeft(deletedAt: Date, now: Date) -> TrashDaysLeft {
        let expiry = deletedAt.addingTimeInterval(Double(retentionDays * 86_400))
        let secs = Int((expiry.timeIntervalSince1970 - now.timeIntervalSince1970).rounded(.towardZero))
        // Python floor division `secs // 86400` for signed integers:
        let rawDays = secs >= 0 ? (secs / 86_400) : ((secs - 86_399) / 86_400)
        return TrashDaysLeft(daysLeft: min(rawDays, retentionDays), expired: secs <= 0)
    }

    // MARK: - Published file identity probe

    public static let defaultIdentityProbe: IdentityProbe = { url in
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        if let cassini = try? CassiniReader.read(data, verifyAudio: false) {
            let own = cassini.manifest?.raw["x"]?["codemyriad.io"]
            if own?["schema"] == .number("1"),
               let origin = own?["origin"]?.string,
               let sessionId = own?["sessionId"]?.string {
                let candidate = "\(origin)-\(sessionId.lowercased())"
                if LibraryScanner.identity(candidate) != nil {
                    let prefix = own?["namePrefix"]?.string.flatMap { LibraryNames.isPrefix($0) ? $0 : nil }
                    let title = cassini.manifest?.meeting.title ?? cassini.tags?["TITLE"]
                    let rawRecorded = cassini.manifest?.meeting.recordedAtUtc ?? cassini.manifest?.meeting.createdAtUtc
                    let recorded = rawRecorded.flatMap(MeetingTime.parseInstant).map(formatUTC)
                    let duration = cassini.manifest?.meeting.durationMs ?? cassini.manifest?.audio.durationMs
                    return PublishedProbeResult(
                        identity: .session(candidate),
                        namePrefix: prefix,
                        title: title,
                        recordedAtUtc: recorded,
                        durationMs: duration
                    )
                }
            }
            if let audio = try? OpusAudioDigest.compute(data) {
                let title = cassini.manifest?.meeting.title ?? cassini.tags?["TITLE"]
                let rawRecorded = cassini.manifest?.meeting.recordedAtUtc ?? cassini.manifest?.meeting.createdAtUtc
                let recorded = rawRecorded.flatMap(MeetingTime.parseInstant).map(formatUTC)
                return PublishedProbeResult(
                    identity: .sha(audio.sha256.lowercased()),
                    namePrefix: nil,
                    title: title,
                    recordedAtUtc: recorded,
                    durationMs: audio.durationMs
                )
            }
            if let manifestSha = cassini.manifest?.integrity.opusAudioSha256.lowercased(), !manifestSha.isEmpty {
                return PublishedProbeResult(identity: .sha(manifestSha))
            }
        }
        if let audio = try? OpusAudioDigest.compute(data) {
            return PublishedProbeResult(identity: .sha(audio.sha256.lowercased()), durationMs: audio.durationMs)
        }
        let fallbackSha = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return PublishedProbeResult(identity: .sha(fallbackSha))
    }

    // MARK: - Folder lock wrapper (backward-compatible coordination with v1 workers)

    /// Coordinates with import publication, metadata edits and speech workers. The
    /// caller stops its own jobs first; another process's busy folder is left alone.
    public static func move(
        _ folder: URL,
        roots: [URL],
        trash: ((URL) throws -> URL?)? = nil
    ) throws -> URL? {
        guard LibraryScanner.identity(folder.lastPathComponent) != nil,
              let rootURL = matchingRoot(for: folder.deletingLastPathComponent(), in: roots) else {
            throw POSIXError(.EPERM)
        }
        if let trash {
            return try withLockedSessionFolder(rootURL: rootURL, relativeSessionPath: folder.lastPathComponent, createIdleSpeechLock: true) {
                try trash(folder)
            }
        }
        let entry = try trashFolder(
            folder,
            roots: roots,
            title: LibraryLocalization.shared.text("library.untitled"),
            recordedAt: nil,
            durationMs: nil,
            now: Date()
        )
        guard let entry else { return nil }
        return rootURL
            .appendingPathComponent(trashDirectory, isDirectory: true)
            .appendingPathComponent(entry.entryId, isDirectory: true)
            .appendingPathComponent(folder.lastPathComponent, isDirectory: true)
    }

    // MARK: - High-level Mac operations

    public static func trashMeeting(
        _ meeting: LibraryMeeting,
        roots: [URL],
        now: Date = Date(),
        activeLease: Bool = false,
        injectBeforeMove: (() throws -> Void)? = nil
    ) throws -> TrashEntry? {
        let fallbackTitle = LibraryLocalization.shared.text("library.untitled")
        let cleanTitle = (meeting.title?.isEmpty == false ? meeting.title : nil) ?? fallbackTitle
        let active = activeLease || meeting.state.lifecycle != .saved
        return try trashFolder(
            meeting.folder,
            roots: roots,
            title: cleanTitle,
            recordedAt: meeting.start,
            durationMs: meeting.durationMs.map(Int.init),
            now: now,
            activeLease: active,
            injectBeforeMove: injectBeforeMove
        )
    }

    public static func trashFolder(
        _ folder: URL,
        roots: [URL],
        title: String,
        recordedAt: Date?,
        durationMs: Int?,
        now: Date = Date(),
        activeLease: Bool = false,
        injectBeforeMove: (() throws -> Void)? = nil
    ) throws -> TrashEntry? {
        let folderName = folder.lastPathComponent
        guard LibraryScanner.identity(folderName) != nil else {
            throw POSIXError(.EPERM)
        }
        let parent = folder.deletingLastPathComponent()
        let rootURL: URL
        let relativeSessionPath: String
        if parent.lastPathComponent == "sessions",
           parent.deletingLastPathComponent().lastPathComponent == ".cassini",
           let matched = matchingRoot(for: parent.deletingLastPathComponent().deletingLastPathComponent(), in: roots) {
            rootURL = matched
            relativeSessionPath = "\(sessionsDirectory)/\(folderName)"
        } else if let matched = matchingRoot(for: parent, in: roots) {
            rootURL = matched
            relativeSessionPath = folderName
        } else {
            throw POSIXError(.EPERM)
        }

        let opId = UUID().uuidString.lowercased()
        let entryId = UUID().uuidString.lowercased()
        let deletedAtUtc = formatUTC(now)
        let recordedAtUtc = recordedAt.map(formatUTC)

        return try withLibraryLock(root: rootURL, createIfMissing: true) {
            try withLockedSessionFolder(rootURL: rootURL, relativeSessionPath: relativeSessionPath, createIdleSpeechLock: false) {
                try injectBeforeMove?()
                // Read persisted namePrefix if present in meeting.json, and find matching published root .opus if any.
                let storedPrefix = readStoredNamePrefix(folder: folder)
                let matchingPublished = try findPublishedFile(
                    forSession: folderName,
                    in: rootURL,
                    probe: defaultIdentityProbe
                )
                let req = TrashRequest(
                    entryId: entryId,
                    deletedAtUtc: deletedAtUtc,
                    title: title,
                    recordedAtUtc: recordedAtUtc,
                    durationMs: durationMs,
                    published: matchingPublished?.name,
                    session: relativeSessionPath,
                    namePrefix: matchingPublished?.namePrefix ?? storedPrefix,
                    activeLease: activeLease
                )
                let fallbackUntitled = LibraryLocalization.shared.text("library.untitled")
                let steps = try plan(
                    in: rootURL,
                    op: opId,
                    request: .trash(req),
                    untitled: fallbackUntitled,
                    probe: defaultIdentityProbe
                )
                try executeSteps(
                    steps,
                    in: rootURL,
                    untitled: fallbackUntitled,
                    probe: defaultIdentityProbe
                )
                return try readEntry(entryId: entryId, in: rootURL)
            }
        }
    }

    @discardableResult
    public static func trash(
        _ request: TrashRequest,
        in root: URL,
        op: String = UUID().uuidString.lowercased(),
        untitled: String? = nil,
        probe: IdentityProbe = defaultIdentityProbe
    ) throws -> TrashEntry {
        let fallbackUntitled = untitled ?? LibraryLocalization.shared.text("library.untitled")
        return try withLibraryLock(root: root, createIfMissing: true) {
            let steps = try plan(in: root, op: op, request: .trash(request), untitled: fallbackUntitled, probe: probe)
            try executeSteps(steps, in: root, untitled: fallbackUntitled, probe: probe)
            guard let entry = try readEntry(entryId: request.entryId, in: root) else {
                throw POSIXError(.ENOENT)
            }
            return entry
        }
    }

    public static func restore(
        entryId: String,
        in root: URL,
        op: String = UUID().uuidString.lowercased(),
        untitled: String? = nil,
        probe: IdentityProbe = defaultIdentityProbe
    ) throws {
        let fallbackUntitled = untitled ?? LibraryLocalization.shared.text("library.untitled")
        try withLibraryLock(root: root, createIfMissing: true) {
            let steps = try plan(in: root, op: op, request: .restore(entryId: entryId), untitled: fallbackUntitled, probe: probe)
            try executeSteps(steps, in: root, untitled: fallbackUntitled, probe: probe)
        }
    }

    public static func purge(
        entryId: String,
        in root: URL,
        op: String = UUID().uuidString.lowercased(),
        untitled: String? = nil,
        probe: IdentityProbe = defaultIdentityProbe
    ) throws {
        let fallbackUntitled = untitled ?? LibraryLocalization.shared.text("library.untitled")
        try withLibraryLock(root: root, createIfMissing: true) {
            let steps = try plan(in: root, op: op, request: .purge(entryId: entryId), untitled: fallbackUntitled, probe: probe)
            try executeSteps(steps, in: root, untitled: fallbackUntitled, probe: probe)
        }
    }

    public static func emptyTrash(
        in root: URL,
        op: String = UUID().uuidString.lowercased(),
        untitled: String? = nil,
        probe: IdentityProbe = defaultIdentityProbe
    ) throws {
        guard cassiniDirectoryExists(in: root) else { return }
        let fallbackUntitled = untitled ?? LibraryLocalization.shared.text("library.untitled")
        try withLibraryLock(root: root, createIfMissing: true) {
            let steps = try plan(in: root, op: op, request: .emptyTrash, untitled: fallbackUntitled, probe: probe)
            try executeSteps(steps, in: root, untitled: fallbackUntitled, probe: probe)
        }
    }

    @discardableResult
    public static func purgeExpired(
        in root: URL,
        now: Date = Date(),
        probe: IdentityProbe = defaultIdentityProbe
    ) throws -> [String] {
        guard cassiniDirectoryExists(in: root) else { return [] }
        let fallbackUntitled = LibraryLocalization.shared.text("library.untitled")
        return try withLibraryLock(root: root, createIfMissing: false) {
            let current = try listEntriesUnlocked(in: root)
            var purged: [String] = []
            for entry in current {
                guard let deletedAt = entry.deletedAt else { continue }
                if daysLeft(deletedAt: deletedAt, now: now).expired {
                    let op = UUID().uuidString.lowercased()
                    let steps = try plan(
                        in: root,
                        op: op,
                        request: .purge(entryId: entry.entryId),
                        untitled: fallbackUntitled,
                        probe: probe
                    )
                    try executeSteps(steps, in: root, untitled: fallbackUntitled, probe: probe)
                    purged.append(entry.entryId)
                }
            }
            return purged
        }
    }

    @discardableResult
    public static func recover(
        in root: URL,
        untitled: String? = nil,
        now: Date = Date(),
        probe: IdentityProbe = defaultIdentityProbe
    ) throws -> [String] {
        guard cassiniDirectoryExists(in: root) else { return [] }
        let fallbackUntitled = untitled ?? LibraryLocalization.shared.text("library.untitled")
        return try withLibraryLock(root: root, createIfMissing: false) {
            try recoverUnlocked(in: root, untitled: fallbackUntitled, now: now, probe: probe)
        }
    }

    public static func entries(in root: URL) throws -> [TrashEntry] {
        guard cassiniDirectoryExists(in: root) else { return [] }
        return try withLibraryLock(root: root, createIfMissing: false) {
            try listEntriesUnlocked(in: root)
        }
    }

    // MARK: - Internal planning & step execution (exposed @testable for TrashVectorsTests)

    enum InternalRequest {
        case trash(TrashRequest)
        case restore(entryId: String)
        case purge(entryId: String)
        case emptyTrash
    }

    static func plan(
        in root: URL,
        op: String,
        request: InternalRequest,
        untitled: String,
        probe: IdentityProbe
    ) throws -> [TrashStep] {
        switch request {
        case .emptyTrash:
            let rows = try listEntriesUnlocked(in: root)
            var out: [TrashStep] = []
            for (index, row) in rows.enumerated() {
                out += try plan(
                    in: root,
                    op: "\(op).\(index + 1)",
                    request: .purge(entryId: row.entryId),
                    untitled: untitled,
                    probe: probe
                )
            }
            return out
        case .trash(let p):
            let (head, steps) = try planTrash(in: root, op: op, p: p, probe: probe)
            return wrapWithJournal(op: op, head: head, steps: steps)
        case .restore(let entryId):
            let (head, steps) = try planRestore(in: root, op: op, entryId: entryId, untitled: untitled, probe: probe)
            return wrapWithJournal(op: op, head: head, steps: steps)
        case .purge(let entryId):
            let (head, steps) = try planPurge(in: root, op: op, entryId: entryId)
            return wrapWithJournal(op: op, head: head, steps: steps)
        }
    }

    private static func wrapWithJournal(op: String, head: [String: Any], steps: [TrashStep]) -> [TrashStep] {
        var journal = head
        journal["steps"] = steps.map(\.jsonObject)
        let path = "\(journalDirectory)/\(op).json"
        let content = canonicalJSON(journal)
        return [TrashStep(action: "writeJournal", path: path, content: content)]
            + steps
            + [TrashStep(action: "retireJournal", path: path)]
    }

    private static func planTrash(
        in root: URL,
        op: String,
        p: TrashRequest,
        probe: IdentityProbe
    ) throws -> ([String: Any], [TrashStep]) {
        if p.activeLease {
            throw TrashError.refused("recording or saving holds the activity lease")
        }
        if p.published == nil && p.session == nil {
            throw TrashError.refused("nothing to move")
        }
        let entryDir = "\(trashDirectory)/\(p.entryId)"
        var publishedObj: TrashPublished?
        var identity: TrashIdentity?

        if let pubName = p.published {
            let pubURL = relativeURL(in: root, path: pubName)
            guard isRegularFileNoFollow(pubURL) else {
                throw TrashError.refused("published file is gone")
            }
            let probed = try probe(pubURL)
            identity = probed.identity
            publishedObj = TrashPublished(name: pubName, namePrefix: p.namePrefix, title: p.title)
        }

        var sessionObj: TrashSession?
        if let sessPath = p.session {
            let sessURL = relativeURL(in: root, path: sessPath)
            guard isDirectoryNoFollow(sessURL) else {
                throw TrashError.refused("working folder is gone")
            }
            let folder = sessPath.split(separator: "/").last.map(String.init) ?? sessPath
            if identity == nil {
                identity = .session(folder)
            } else if case .session(let pubFolder) = identity, pubFolder != folder {
                throw TrashError.refused("published file and working folder have different identities")
            } else if case .sha = identity {
                // Keep sha identity if file had no session link; session matches only if nil or folder.
            }
            let layout = sessPath.contains("/") ? "v2" : "v1"
            sessionObj = TrashSession(path: sessPath, layout: layout)
        }

        guard let resolvedIdentity = identity else {
            throw TrashError.refused("nothing to move")
        }

        // Refuse if another pending journal entry already references this entryId.
        if hasPendingJournal(in: root, entryId: p.entryId) {
            throw TrashError.refused("pending journal entry exists")
        }

        let live = try liveRepresentations(in: root, probe: probe)
        let others = live.compactMap { item -> String? in
            guard item.identityKey == resolvedIdentity.key,
                  item.path != p.published,
                  item.path.hasSuffix(".opus") else { return nil }
            return item.path
        }
        if !others.isEmpty && publishedObj == nil {
            throw TrashError.refused("a published file with this identity is still in the Library")
        }
        if !others.isEmpty && sessionObj != nil {
            // Working folder stays with the live duplicate published copy.
            sessionObj = nil
        }

        let entryDict: [String: Any] = [
            "version": 1,
            "entryId": p.entryId,
            "deletedAtUtc": p.deletedAtUtc,
            "identity": resolvedIdentity.jsonObject,
            "published": publishedObj?.jsonObject ?? NSNull(),
            "session": sessionObj?.jsonObject ?? NSNull(),
            "display": TrashDisplay(
                title: p.title,
                recordedAtUtc: p.recordedAtUtc,
                durationMs: p.durationMs
            ).jsonObject,
        ]

        var steps: [TrashStep] = [
            TrashStep(action: "mkdir", path: trashDirectory),
            TrashStep(action: "mkdir", path: entryDir),
            TrashStep(action: "writeFile", path: "\(entryDir)/\(entryFileName)", content: canonicalJSON(entryDict)),
        ]
        if let publishedObj {
            steps.append(TrashStep(
                action: "move",
                from: publishedObj.name,
                to: "\(entryDir)/\(publishedEntryFileName)"
            ))
        }
        if let sessionObj {
            steps.append(TrashStep(
                action: "move",
                from: sessionObj.path,
                to: "\(entryDir)/\(sessionObj.folderName)"
            ))
        }
        return (["op": op, "kind": "trash", "entryId": p.entryId], steps)
    }

    static func restoreName(
        published: TrashPublished,
        existing: [String],
        untitled: String,
        skip: [String] = []
    ) throws -> String {
        let allExisting = existing + skip
        let taken = Set(allExisting.map(LibraryNames.fold))
        if !taken.contains(LibraryNames.fold(published.name)) {
            return published.name
        }
        if let prefix = published.namePrefix, LibraryNames.isPrefix(prefix) {
            return try LibraryNames.fileName(
                prefix: prefix,
                title: published.title,
                untitled: untitled,
                existing: allExisting
            ).name
        }
        let ext = LibraryNames.fileExtension
        let stem = published.name.hasSuffix(ext)
            ? String(published.name.dropLast(ext.count))
            : published.name
        let scalars = Array(LibraryNames.nfc(stem).unicodeScalars)
        for n in 2..<(2 + maxSuffixRetries) {
            let suffix = " (\(n))"
            let budget = LibraryNames.maxBytes - suffix.utf8.count - ext.utf8.count
            var cut = LibraryNames.truncate(scalars, limit: budget)
            while let last = cut.last, last.value == 0x20 || last.value == 0x2E {
                cut.removeLast()
            }
            var view = String.UnicodeScalarView()
            view.append(contentsOf: cut)
            let candidate = String(view) + suffix + ext
            if !taken.contains(LibraryNames.fold(candidate)) {
                return candidate
            }
        }
        throw TrashError.refused("no free name")
    }

    private static func planRestore(
        in root: URL,
        op: String,
        entryId: String,
        untitled: String,
        probe: IdentityProbe
    ) throws -> ([String: Any], [TrashStep]) {
        let entryDir = "\(trashDirectory)/\(entryId)"
        let entryURL = relativeURL(in: root, path: "\(entryDir)/\(entryFileName)")
        guard isRegularFileNoFollow(entryURL),
              let raw = try? readJSONDictionary(at: entryURL),
              let entry = parseEntry(raw, entryId: entryId, root: root) else {
            throw TrashError.refused("no such entry")
        }

        let live = Set(try liveRepresentations(in: root, probe: probe).map(\.identityKey))
        if live.contains(entry.identity.key) {
            throw TrashError.refused("a meeting with this identity is already in the Library")
        }

        var steps: [TrashStep] = []
        if let session = entry.session {
            let folder = session.folderName
            if existsNoFollow(relativeURL(in: root, path: "\(sessionsDirectory)/\(folder)"))
                || existsNoFollow(relativeURL(in: root, path: folder)) {
                throw TrashError.refused("a meeting with this identity is already in the Library")
            }
            if session.layout == "v2" {
                steps.append(TrashStep(action: "mkdir", path: sessionsDirectory))
            }
            steps.append(TrashStep(
                action: "move",
                from: "\(entryDir)/\(folder)",
                to: session.path
            ))
        }
        if let published = entry.published {
            let chosen = try restoreName(
                published: published,
                existing: takenRootOpusNames(in: root),
                untitled: untitled
            )
            steps.append(TrashStep(
                action: "move",
                from: "\(entryDir)/\(publishedEntryFileName)",
                to: chosen,
                nameFrom: "restoreName"
            ))
        }
        steps.append(TrashStep(action: "remove", path: "\(entryDir)/\(entryFileName)"))
        steps.append(TrashStep(action: "removeTree", path: entryDir))
        return (["op": op, "kind": "restore", "entryId": entryId], steps)
    }

    private static func planPurge(
        in root: URL,
        op: String,
        entryId: String
    ) throws -> ([String: Any], [TrashStep]) {
        let entryDir = "\(trashDirectory)/\(entryId)"
        guard isDirectoryNoFollow(relativeURL(in: root, path: entryDir)) else {
            throw TrashError.refused("no such entry")
        }
        let purgeDir = "\(trashDirectory)/.purge-\(entryId)"
        let entryURL = relativeURL(in: root, path: "\(entryDir)/\(entryFileName)")
        let parsed: TrashEntry? = isRegularFileNoFollow(entryURL)
            ? (try? readJSONDictionary(at: entryURL)).flatMap { parseEntry($0, entryId: entryId, root: root) }
            : nil

        var steps: [TrashStep] = [
            TrashStep(action: "move", from: entryDir, to: purgeDir),
        ]
        if parsed?.published != nil {
            steps.append(TrashStep(action: "remove", path: "\(purgeDir)/\(publishedEntryFileName)"))
        }
        if let session = parsed?.session {
            steps.append(TrashStep(action: "removeTree", path: "\(purgeDir)/\(session.folderName)"))
        }
        steps.append(TrashStep(action: "remove", path: "\(purgeDir)/\(entryFileName)"))
        steps.append(TrashStep(action: "removeTree", path: purgeDir))
        return (["op": op, "kind": "purge", "entryId": entryId], steps)
    }

    static func executeSteps(
        _ steps: [TrashStep],
        in root: URL,
        untitled: String,
        probe: IdentityProbe,
        stopAfterStep: Int? = nil
    ) throws {
        var activeJournalPath: String?
        for (index, step) in steps.enumerated() {
            if let stopAfterStep, index >= stopAfterStep {
                break
            }
            if step.action == "writeJournal" {
                activeJournalPath = step.path
            }
            try applyStep(
                step,
                in: root,
                untitled: untitled,
                replay: false,
                journalPath: activeJournalPath
            )
            if step.action == "retireJournal" {
                activeJournalPath = nil
            }
        }
    }

    static func applyStep(
        _ step: TrashStep,
        in root: URL,
        untitled: String,
        replay: Bool,
        journalPath: String?
    ) throws {
        switch step.action {
        case "mkdir":
            guard let path = step.path else { throw POSIXError(.EINVAL) }
            try ensureRelativeDirectory(in: root, path: path)

        case "writeJournal":
            guard let path = step.path, let content = step.content else { throw POSIXError(.EINVAL) }
            try ensureRelativeDirectory(in: root, path: journalDirectory)
            try atomicWriteRelativeFile(in: root, path: path, content: content)

        case "writeFile":
            guard let path = step.path, let content = step.content else { throw POSIXError(.EINVAL) }
            let parent = (path as NSString).deletingLastPathComponent
            if !parent.isEmpty {
                try ensureRelativeDirectory(in: root, path: parent)
            }
            try atomicWriteRelativeFile(in: root, path: path, content: content)

        case "move":
            guard let src = step.from, let initialDst = step.to else { throw POSIXError(.EINVAL) }
            var dst = initialDst
            let srcURL = relativeURL(in: root, path: src)
            let dstURL = relativeURL(in: root, path: dst)
            let haveSrc = existsNoFollow(srcURL)
            let haveDst = existsNoFollow(dstURL)

            if replay {
                if !haveSrc && haveDst {
                    return // already done
                }
                if !haveSrc && !haveDst {
                    return // missing: skip
                }
                if haveSrc && haveDst && step.nameFrom != "restoreName" {
                    throw TrashError.conflict("\(src) and \(dst) both exist")
                }
            }

            if step.nameFrom == "restoreName" {
                var skip: [String] = []
                if replay && haveDst {
                    // Journaled restore name was taken while crashed; recompute immediately.
                    dst = try nextRestoreDestination(
                        src: src,
                        in: root,
                        untitled: untitled,
                        skip: skip,
                        journalPath: journalPath
                    )
                }
                var attempts = 0
                while true {
                    do {
                        try atomicRenameNoReplace(in: root, from: src, to: dst)
                        return
                    } catch let err as POSIXError where err.code == .EEXIST && attempts < maxSuffixRetries {
                        attempts += 1
                        skip.append(dst)
                        dst = try nextRestoreDestination(
                            src: src,
                            in: root,
                            untitled: untitled,
                            skip: skip,
                            journalPath: journalPath
                        )
                    }
                }
            } else {
                try atomicRenameNoReplace(in: root, from: src, to: dst)
            }

        case "remove":
            guard let path = step.path else { throw POSIXError(.EINVAL) }
            try removeRelativeFileIfPresent(in: root, path: path)

        case "removeTree":
            guard let path = step.path else { throw POSIXError(.EINVAL) }
            try removeRelativeTreeIfPresent(in: root, path: path)

        case "retireJournal":
            guard let path = step.path else { throw POSIXError(.EINVAL) }
            try removeRelativeFileIfPresent(in: root, path: path, syncParent: true)

        default:
            throw POSIXError(.EINVAL)
        }
    }

    private static func nextRestoreDestination(
        src: String,
        in root: URL,
        untitled: String,
        skip: [String],
        journalPath: String?
    ) throws -> String {
        let parentDir = (src as NSString).deletingLastPathComponent
        let entryURL = relativeURL(in: root, path: "\(parentDir)/\(entryFileName)")
        guard let raw = try? readJSONDictionary(at: entryURL),
              let published = TrashPublished.fromJSON(raw["published"]) else {
            throw TrashError.refused("no such entry")
        }
        let chosen = try restoreName(
            published: published,
            existing: takenRootOpusNames(in: root),
            untitled: untitled,
            skip: skip
        )
        if let journalPath {
            let jURL = relativeURL(in: root, path: journalPath)
            if var journal = try? readJSONDictionary(at: jURL),
               var rawSteps = journal["steps"] as? [[String: Any]] {
                for idx in rawSteps.indices where rawSteps[idx]["nameFrom"] as? String == "restoreName" {
                    rawSteps[idx]["to"] = chosen
                }
                journal["steps"] = rawSteps
                try atomicWriteRelativeFile(in: root, path: journalPath, content: canonicalJSON(journal))
            }
        }
        return chosen
    }

    private static func recoverUnlocked(
        in root: URL,
        untitled: String,
        now: Date,
        probe: IdentityProbe
    ) throws -> [String] {
        var report: [String] = []
        let journalDirURL = relativeURL(in: root, path: journalDirectory)
        if isDirectoryNoFollow(journalDirURL) {
            let names = (try? directoryChildren(at: journalDirURL))?
                .filter { $0.hasSuffix(".json") && !$0.hasPrefix(".") }
                .sorted() ?? []
            for name in names {
                let relPath = "\(journalDirectory)/\(name)"
                let jURL = relativeURL(in: root, path: relPath)
                guard let journal = try? readJSONDictionary(at: jURL),
                      let kind = journal["kind"] as? String,
                      let entryId = journal["entryId"] as? String,
                      let rawSteps = journal["steps"] as? [[String: Any]] else {
                    continue
                }
                let steps = rawSteps.compactMap(TrashStep.fromJSON)
                do {
                    for step in steps {
                        try applyStep(step, in: root, untitled: untitled, replay: true, journalPath: relPath)
                    }
                    try removeRelativeFileIfPresent(in: root, path: relPath, syncParent: true)
                    report.append("replayed \(kind) \(entryId)")
                } catch TrashError.conflict(let message) {
                    report.append("conflict in \(kind) \(entryId): \(message)")
                }
            }
        }

        // Gather any remaining conflicted journal entryIds so we never sweep or rebuild them.
        var pendingIds = Set<String>()
        if isDirectoryNoFollow(journalDirURL) {
            for name in (try? directoryChildren(at: journalDirURL)) ?? [] where name.hasSuffix(".json") && !name.hasPrefix(".") {
                if let j = try? readJSONDictionary(at: journalDirURL.appendingPathComponent(name)),
                   let eid = j["entryId"] as? String {
                    pendingIds.insert(eid)
                }
            }
        }

        let trashDirURL = relativeURL(in: root, path: trashDirectory)
        if isDirectoryNoFollow(trashDirURL) {
            let children = ((try? directoryChildren(at: trashDirURL)) ?? []).sorted()
            for name in children {
                if name.hasPrefix(".purge-") {
                    let targetId = String(name.dropFirst(".purge-".count))
                    if !pendingIds.contains(targetId) {
                        try removeRelativeTreeIfPresent(in: root, path: "\(trashDirectory)/\(name)")
                        report.append("swept \(name)")
                    }
                    continue
                }
                if name.hasPrefix(".") || name.hasSuffix(".partial") || pendingIds.contains(name) {
                    continue
                }
                let entryDirRel = "\(trashDirectory)/\(name)"
                let entryDirURL = relativeURL(in: root, path: entryDirRel)
                guard isDirectoryNoFollow(entryDirURL) else { continue }
                let entryFileURL = entryDirURL.appendingPathComponent(entryFileName)
                if !isRegularFileNoFollow(entryFileURL) {
                    if try rebuildMissingEntryFile(
                        entryId: name,
                        entryDirRel: entryDirRel,
                        in: root,
                        untitled: untitled,
                        now: now,
                        probe: probe
                    ) {
                        report.append("rebuilt \(name)")
                    }
                }
            }
        }
        return report
    }

    /// S-12 §7.1: a directory in `.cassini/trash/` without `entry.json` and without a pending
    /// journal entry gets one rebuilt from its contents, dated at discovery.
    private static func rebuildMissingEntryFile(
        entryId: String,
        entryDirRel: String,
        in root: URL,
        untitled: String,
        now: Date,
        probe: IdentityProbe
    ) throws -> Bool {
        let entryDirURL = relativeURL(in: root, path: entryDirRel)
        let items = (try? directoryChildren(at: entryDirURL)) ?? []
        let pubURL = entryDirURL.appendingPathComponent(publishedEntryFileName)
        let hasPub = items.contains(publishedEntryFileName) && isRegularFileNoFollow(pubURL)
        let sessionFolder = items.first { LibraryScanner.identity($0) != nil && isDirectoryNoFollow(entryDirURL.appendingPathComponent($0)) }
        guard hasPub || sessionFolder != nil else { return false }

        var identity: TrashIdentity?
        var publishedObj: TrashPublished?
        var title = untitled
        var recordedAtUtc: String?
        var durationMs: Int?

        if hasPub, let probed = try? probe(pubURL) {
            identity = probed.identity
            if let t = probed.title, !t.isEmpty { title = t }
            recordedAtUtc = probed.recordedAtUtc
            durationMs = probed.durationMs
            let restoredName: String
            if let prefix = probed.namePrefix, LibraryNames.isPrefix(prefix),
               let built = try? LibraryNames.fileName(prefix: prefix, title: title, untitled: untitled).name {
                restoredName = built
            } else {
                restoredName = LibraryNames.sanitize(title, untitled: untitled) + LibraryNames.fileExtension
            }
            publishedObj = TrashPublished(name: restoredName, namePrefix: probed.namePrefix, title: title)
        }

        var sessionObj: TrashSession?
        if let sessionFolder {
            let folderURL = entryDirURL.appendingPathComponent(sessionFolder)
            if identity == nil {
                identity = .session(sessionFolder)
            }
            if let inspected = LibraryScanner(root: entryDirURL).meeting(at: folderURL, now: now) {
                if publishedObj == nil {
                    if let t = inspected.title, !t.isEmpty { title = t }
                    recordedAtUtc = inspected.start.map(formatUTC)
                    durationMs = inspected.durationMs.map(Int.init)
                }
            }
            // Prefer v2 layout if `.cassini/sessions` exists in root, else v1.
            let layout = isDirectoryNoFollow(relativeURL(in: root, path: sessionsDirectory)) ? "v2" : "v1"
            let sessionPath = layout == "v2" ? "\(sessionsDirectory)/\(sessionFolder)" : sessionFolder
            _ = folderURL
            sessionObj = TrashSession(path: sessionPath, layout: layout)
        }

        guard let resolvedIdentity = identity else { return false }
        let entryDict: [String: Any] = [
            "version": 1,
            "entryId": entryId,
            "deletedAtUtc": formatUTC(now),
            "identity": resolvedIdentity.jsonObject,
            "published": publishedObj?.jsonObject ?? NSNull(),
            "session": sessionObj?.jsonObject ?? NSNull(),
            "display": TrashDisplay(title: title, recordedAtUtc: recordedAtUtc, durationMs: durationMs).jsonObject,
        ]
        try atomicWriteRelativeFile(
            in: root,
            path: "\(entryDirRel)/\(entryFileName)",
            content: canonicalJSON(entryDict)
        )
        return true
    }

    // MARK: - Live representations & Trash entries query

    struct LiveItem {
        let identityKey: String
        let path: String
    }

    static func liveRepresentations(in root: URL, probe: IdentityProbe) throws -> [LiveItem] {
        var out: [LiveItem] = []
        let rootChildren = ((try? directoryChildren(at: root)) ?? []).sorted()
        for name in rootChildren where !name.hasPrefix(".") {
            let childURL = root.appendingPathComponent(name)
            if name.hasSuffix(".opus"), isRegularFileNoFollow(childURL) {
                let probed = try probe(childURL)
                out.append(LiveItem(identityKey: probed.identity.key, path: name))
            } else if LibraryScanner.identity(name) != nil, isDirectoryNoFollow(childURL) {
                out.append(LiveItem(identityKey: name, path: name))
            }
        }
        let sessionsURL = relativeURL(in: root, path: sessionsDirectory)
        if isDirectoryNoFollow(sessionsURL) {
            let sessChildren = ((try? directoryChildren(at: sessionsURL)) ?? []).sorted()
            for name in sessChildren where LibraryScanner.identity(name) != nil {
                if isDirectoryNoFollow(sessionsURL.appendingPathComponent(name)) {
                    out.append(LiveItem(identityKey: name, path: "\(sessionsDirectory)/\(name)"))
                }
            }
        }
        return out
    }

    static func listEntriesUnlocked(in root: URL) throws -> [TrashEntry] {
        let trashURL = relativeURL(in: root, path: trashDirectory)
        guard isDirectoryNoFollow(trashURL) else { return [] }
        var rows: [TrashEntry] = []
        for entryId in (try? directoryChildren(at: trashURL)) ?? [] {
            if entryId.hasPrefix(".") || entryId.hasSuffix(".partial") { continue }
            let entryDirURL = trashURL.appendingPathComponent(entryId)
            guard isDirectoryNoFollow(entryDirURL) else { continue }
            let fileURL = entryDirURL.appendingPathComponent(entryFileName)
            guard isRegularFileNoFollow(fileURL),
                  let raw = try? readJSONDictionary(at: fileURL),
                  let parsed = parseEntry(raw, entryId: entryId, root: root) else { continue }
            rows.append(parsed)
        }
        rows.sort { a, b in
            if a.deletedAtUtc != b.deletedAtUtc {
                return a.deletedAtUtc > b.deletedAtUtc
            }
            return a.entryId > b.entryId
        }
        return rows
    }

    private static func readEntry(entryId: String, in root: URL) throws -> TrashEntry? {
        let fileURL = relativeURL(in: root, path: "\(trashDirectory)/\(entryId)/\(entryFileName)")
        guard isRegularFileNoFollow(fileURL),
              let raw = try? readJSONDictionary(at: fileURL) else { return nil }
        return parseEntry(raw, entryId: entryId, root: root)
    }

    private static func parseEntry(_ raw: [String: Any], entryId: String, root: URL) -> TrashEntry? {
        guard let deletedAtUtc = raw["deletedAtUtc"] as? String,
              let identity = TrashIdentity.fromJSON(raw["identity"]),
              let display = TrashDisplay.fromJSON(raw["display"]) else {
            return nil
        }
        let published = TrashPublished.fromJSON(raw["published"])
        let session = TrashSession.fromJSON(raw["session"])
        return TrashEntry(
            root: root,
            entryId: (raw["entryId"] as? String) ?? entryId,
            deletedAtUtc: deletedAtUtc,
            identity: identity,
            published: published,
            session: session,
            display: display
        )
    }

    private static func takenRootOpusNames(in root: URL) -> [String] {
        ((try? directoryChildren(at: root)) ?? [])
            .filter { !$0.hasPrefix(".") && $0.hasSuffix(".opus") && isRegularFileNoFollow(root.appendingPathComponent($0)) }
            .sorted()
    }

    private static func hasPendingJournal(in root: URL, entryId: String) -> Bool {
        let jDir = relativeURL(in: root, path: journalDirectory)
        guard isDirectoryNoFollow(jDir) else { return false }
        for name in (try? directoryChildren(at: jDir)) ?? [] where name.hasSuffix(".json") && !name.hasPrefix(".") {
            if let dict = try? readJSONDictionary(at: jDir.appendingPathComponent(name)),
               dict["entryId"] as? String == entryId {
                return true
            }
        }
        return false
    }

    private static func readStoredNamePrefix(folder: URL) -> String? {
        let url = folder.appendingPathComponent("meeting.json")
        guard isRegularFileNoFollow(url),
              let data = try? Data(contentsOf: url),
              let parsed = try? JSONParser.parse(data),
              let prefix = parsed["namePrefix"]?.string,
              LibraryNames.isPrefix(prefix) else { return nil }
        return prefix
    }

    private static func findPublishedFile(
        forSession sessionFolder: String,
        in root: URL,
        probe: IdentityProbe
    ) throws -> (name: String, namePrefix: String?)? {
        for name in takenRootOpusNames(in: root) {
            let url = root.appendingPathComponent(name)
            if let probed = try? probe(url), probed.identity == .session(sessionFolder) {
                return (name, probed.namePrefix)
            }
        }
        return nil
    }

    // MARK: - POSIX locking & atomic filesystem primitives

    private static func matchingRoot(for candidate: URL, in roots: [URL]) -> URL? {
        let target = LibraryLocation.canonical(candidate)
        return roots.first { LibraryLocation.canonical($0) == target }
    }

    private static func cassiniDirectoryExists(in root: URL) -> Bool {
        var info = stat()
        let path = root.path + "/.cassini"
        guard lstat(path, &info) == 0 else { return false }
        return (info.st_mode & S_IFMT) == S_IFDIR
    }

    static func withLibraryLock<T>(
        root: URL,
        createIfMissing: Bool,
        body: () throws -> T
    ) throws -> T {
        let rootFd = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard rootFd >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .ENOENT)
        }
        defer { close(rootFd) }

        if mkdirat(rootFd, ".cassini", 0o700) != 0 {
            let err = errno
            if err == ENOENT && !createIfMissing {
                throw POSIXError(.ENOENT)
            }
            if err != EEXIST {
                throw POSIXError(POSIXErrorCode(rawValue: err) ?? .EACCES)
            }
        }
        let cassiniFd = openat(rootFd, ".cassini", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard cassiniFd >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EPERM)
        }
        defer { close(cassiniFd) }

        let lockFlags = O_RDWR | (createIfMissing ? O_CREAT : (O_CREAT)) | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC
        let lockFd = openat(cassiniFd, "library.lock", lockFlags, 0o600)
        guard lockFd >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EACCES)
        }
        defer { close(lockFd) }

        var info = stat()
        guard fstat(lockFd, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == getuid() else {
            throw POSIXError(.EPERM)
        }

        while flock(lockFd, LOCK_EX) != 0 {
            if errno == EINTR { continue }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EBUSY)
        }
        defer { flock(lockFd, LOCK_UN) }
        return try body()
    }

    private static func withLockedSessionFolder<T>(
        rootURL: URL,
        relativeSessionPath: String,
        createIdleSpeechLock: Bool,
        body: () throws -> T?
    ) throws -> T? {
        let rootFd = open(rootURL.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard rootFd >= 0 else { throw POSIXError(.ENOENT) }
        defer { close(rootFd) }
        guard flock(rootFd, LOCK_EX | LOCK_NB) == 0 else { throw POSIXError(.EBUSY) }
        defer { flock(rootFd, LOCK_UN) }

        let (parentFd, closeParent, baseName) = try openRelativeParent(rootFd: rootFd, relativePath: relativeSessionPath)
        defer { if closeParent { close(parentFd) } }

        let directory = openat(parentFd, baseName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if directory < 0, errno == ENOENT { return nil }
        guard directory >= 0 else { throw POSIXError(.EPERM) }
        defer { close(directory) }

        guard flock(directory, LOCK_EX | LOCK_NB) == 0 else { throw POSIXError(.EBUSY) }
        defer { flock(directory, LOCK_UN) }

        let speechFlags = O_RDWR | (createIdleSpeechLock ? O_CREAT : 0) | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC
        let speech = openat(directory, ".transcription.lock", speechFlags, 0o600)
        if speech >= 0 {
            var info = stat()
            guard fstat(speech, &info) == 0,
                  (info.st_mode & S_IFMT) == S_IFREG,
                  info.st_nlink == 1,
                  info.st_uid == getuid(),
                  flock(speech, LOCK_EX | LOCK_NB) == 0 else {
                close(speech)
                throw POSIXError(.EBUSY)
            }
        } else if errno != ENOENT {
            throw POSIXError(.EBUSY)
        }
        defer {
            if speech >= 0 {
                flock(speech, LOCK_UN)
                close(speech)
            }
        }

        var opened = stat(), named = stat()
        guard fstat(directory, &opened) == 0,
              fstatat(parentFd, baseName, &named, AT_SYMLINK_NOFOLLOW) == 0,
              opened.st_dev == named.st_dev,
              opened.st_ino == named.st_ino else {
            throw POSIXError(.EBUSY)
        }
        return try body()
    }

    private static func openRelativeParent(
        rootFd: Int32,
        relativePath: String,
        createIntermediate: Bool = false
    ) throws -> (fd: Int32, shouldClose: Bool, baseName: String) {
        let parts = relativePath.split(separator: "/").map(String.init)
        guard let last = parts.last, !last.isEmpty, last != ".", last != ".." else {
            throw POSIXError(.EINVAL)
        }
        if parts.count == 1 {
            return (rootFd, false, last)
        }
        var currentFd = rootFd
        var closeCurrent = false
        for dirName in parts.dropLast() {
            guard !dirName.isEmpty, dirName != ".", dirName != ".." else {
                if closeCurrent { close(currentFd) }
                throw POSIXError(.EINVAL)
            }
            if createIntermediate {
                if mkdirat(currentFd, dirName, 0o700) != 0 && errno != EEXIST {
                    let code = POSIXErrorCode(rawValue: errno) ?? .EACCES
                    if closeCurrent { close(currentFd) }
                    throw POSIXError(code)
                }
            }
            let nextFd = openat(currentFd, dirName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            if closeCurrent { close(currentFd) }
            guard nextFd >= 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .ENOENT)
            }
            currentFd = nextFd
            closeCurrent = true
        }
        return (currentFd, closeCurrent, last)
    }

    private static func ensureRelativeDirectory(in root: URL, path: String) throws {
        let rootFd = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard rootFd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .ENOENT) }
        defer { close(rootFd) }

        let parts = path.split(separator: "/").map(String.init)
        var currentFd = rootFd
        var closeCurrent = false
        defer { if closeCurrent { close(currentFd) } }

        for part in parts {
            guard !part.isEmpty, part != ".", part != ".." else { throw POSIXError(.EINVAL) }
            var created = false
            if mkdirat(currentFd, part, 0o700) == 0 {
                created = true
            } else if errno != EEXIST {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EACCES)
            }
            if created {
                _ = fsync(currentFd)
            }
            let nextFd = openat(currentFd, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard nextFd >= 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EPERM)
            }
            if closeCurrent { close(currentFd) }
            currentFd = nextFd
            closeCurrent = true
        }
    }

    private static func atomicWriteRelativeFile(in root: URL, path: String, content: String) throws {
        let rootFd = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard rootFd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .ENOENT) }
        defer { close(rootFd) }

        let (parentFd, closeParent, baseName) = try openRelativeParent(
            rootFd: rootFd,
            relativePath: path,
            createIntermediate: true
        )
        defer { if closeParent { close(parentFd) } }

        let tempName = ".\(baseName).tmp-\(UUID().uuidString.lowercased())"
        let tempFd = openat(parentFd, tempName, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard tempFd >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EACCES)
        }
        var closedTemp = false
        defer {
            if !closedTemp { close(tempFd) }
            _ = unlinkat(parentFd, tempName, 0)
        }

        let bytes = Array(content.utf8)
        try bytes.withUnsafeBufferPointer { buffer in
            var offset = 0
            while offset < buffer.count {
                let n = Darwin.write(tempFd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                offset += n
            }
        }
        guard fsync(tempFd) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        closedTemp = true
        guard close(tempFd) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard renameat(parentFd, tempName, parentFd, baseName) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        _ = fsync(parentFd)
    }

    private static func atomicRenameNoReplace(in root: URL, from src: String, to dst: String) throws {
        let rootFd = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard rootFd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .ENOENT) }
        defer { close(rootFd) }

        let (srcParent, closeSrc, srcBase) = try openRelativeParent(rootFd: rootFd, relativePath: src)
        defer { if closeSrc { close(srcParent) } }
        let (dstParent, closeDst, dstBase) = try openRelativeParent(rootFd: rootFd, relativePath: dst)
        defer { if closeDst { close(dstParent) } }

        guard renameatx_np(srcParent, srcBase, dstParent, dstBase, UInt32(RENAME_EXCL)) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        _ = fsync(srcParent)
        if dstParent != srcParent {
            _ = fsync(dstParent)
        }
    }

    private static func removeRelativeFileIfPresent(in root: URL, path: String, syncParent: Bool = false) throws {
        let rootFd = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard rootFd >= 0 else { return }
        defer { close(rootFd) }

        guard let (parentFd, closeParent, baseName) = try? openRelativeParent(rootFd: rootFd, relativePath: path) else {
            return
        }
        defer { if closeParent { close(parentFd) } }

        if unlinkat(parentFd, baseName, 0) != 0 && errno != ENOENT {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        if syncParent {
            _ = fsync(parentFd)
        }
    }

    private static func removeRelativeTreeIfPresent(in root: URL, path: String) throws {
        let rootFd = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard rootFd >= 0 else { return }
        defer { close(rootFd) }

        guard let (parentFd, closeParent, baseName) = try? openRelativeParent(rootFd: rootFd, relativePath: path) else {
            return
        }
        defer { if closeParent { close(parentFd) } }
        try removeChildRecursive(parentFd: parentFd, name: baseName)
        _ = fsync(parentFd)
    }

    private static func removeChildRecursive(parentFd: Int32, name: String) throws {
        guard !name.isEmpty, name != ".", name != ".." else { throw POSIXError(.EINVAL) }
        var info = stat()
        if fstatat(parentFd, name, &info, AT_SYMLINK_NOFOLLOW) != 0 {
            if errno == ENOENT { return }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        if (info.st_mode & S_IFMT) == S_IFDIR {
            let dirFd = openat(parentFd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard dirFd >= 0 else {
                if errno == ENOENT { return }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            let children = try directoryChildren(fd: dirFd)
            for child in children {
                try removeChildRecursive(parentFd: dirFd, name: child)
            }
            close(dirFd)
            if unlinkat(parentFd, name, AT_REMOVEDIR) != 0 && errno != ENOENT {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        } else {
            if unlinkat(parentFd, name, 0) != 0 && errno != ENOENT {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }
    }

    private static func directoryChildren(at url: URL) throws -> [String] {
        let fd = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .ENOENT) }
        return try directoryChildren(fd: fd, closeFd: true)
    }

    private static func directoryChildren(fd: Int32, closeFd: Bool = false) throws -> [String] {
        let dupFd = closeFd ? fd : dup(fd)
        guard dupFd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EBADF) }
        guard let dir = fdopendir(dupFd) else {
            close(dupFd)
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { closedir(dir) }
        var out: [String] = []
        while let ent = readdir(dir) {
            let name = withUnsafePointer(to: ent.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(ent.pointee.d_namlen) + 1) {
                    String(cString: $0)
                }
            }
            if name == "." || name == ".." { continue }
            out.append(name)
        }
        return out
    }

    private static func relativeURL(in root: URL, path: String) -> URL {
        // Build path by appending raw path string so Foundation does not alter NFC/NFD normalization.
        URL(fileURLWithPath: root.path + "/" + path)
    }

    private static func existsNoFollow(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0
    }

    private static func isRegularFileNoFollow(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFREG
    }

    private static func isDirectoryNoFollow(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR
    }

    private static func canonicalJSON(_ object: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    private static func readJSONDictionary(at url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        guard let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw POSIXError(.EINVAL)
        }
        return dict
    }
}
