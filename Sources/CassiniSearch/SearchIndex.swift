// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import CryptoKit
import Darwin
import SQLite3
import CassiniLibrary

public enum SearchDate: Sendable, CaseIterable { case any, today, week, month
    public func contains(_ date: Date?, now: Date, timeZone: TimeZone) -> Bool {
        guard self != .any else { return true }; guard let date else { return false }
        var calendar = Calendar(identifier:.gregorian); calendar.timeZone = timeZone
        let midnight = calendar.startOfDay(for:now)
        let first = calendar.date(byAdding:.day,value:self == .month ? -29 : self == .week ? -6 : 0,to:midnight)!
        let last = calendar.date(byAdding:.day,value:1,to:midnight)!
        return date >= first && date < last
    }
}
public struct SearchFilter: Sendable {
    public var speaker: String?
    public var date: SearchDate
    public var own: Bool
    public init(speaker: String? = nil, date: SearchDate = .any, own: Bool = false) { self.speaker = speaker; self.date = date; self.own = own }
}
public struct SearchSpan: Sendable, Equatable { public let start: Int; public let length: Int }
public struct SearchHit: Sendable, Identifiable {
    public let meetingKey: String
    public let turn: Int
    public let positionMs: Int64
    public let speaker: String
    public let text: String
    /// UTF16 positions in the original normalised turn, including all matches.
    public let spans: [SearchSpan]
    public let occurrence: Int
    public var id: String { meetingKey + ":\(turn):\(occurrence)" }
    public var excerpt: (text: String, spans: [SearchSpan]) {
        guard let selected = spans.dropFirst(occurrence).first,
              let range = Range(NSRange(location:selected.start,length:selected.length),in:text) else { return (text,[]) }
        let lower = text.index(range.lowerBound,offsetBy:-70,limitedBy:text.startIndex) ?? text.startIndex
        let upper = text.index(range.upperBound,offsetBy:100,limitedBy:text.endIndex) ?? text.endIndex
        let prefix = lower == text.startIndex ? "" : "…", suffix = upper == text.endIndex ? "" : "…"
        let skipped = text[..<lower].utf16.count
        let clipped = String(text[lower..<upper])
        let kept = clipped.utf16.count
        let highlights = spans.compactMap { span -> SearchSpan? in
            let a = max(span.start,skipped), b = min(span.start + span.length,skipped + kept)
            return b > a ? .init(start:a - skipped + prefix.utf16.count,length:b - a) : nil
        }
        return (prefix + clipped + suffix,highlights)
    }
}

/// The only writer is this actor. The cache is derived from read-only scanner
/// snapshots; no session file is ever opened for writing by Search.
public actor SearchIndex {
    private let database: SearchDatabase
    private var meetings: [String:LibraryMeeting] = [:]
    private var fingerprints: [String:Data] = [:]
    private var turns: [String:[MeetingPresentation.Turn]] = [:]
    public init(cache: URL) throws { database = try SearchDatabase(cache:cache) }
    public static func names(_ meetings: [LibraryMeeting]) -> [String] {
        var names: [String:String] = [:]
        for speaker in meetings.flatMap(\.speakers) where speaker.provenance != .unnamed {
            guard let name = speaker.name, !name.isEmpty else { continue }
            let key = name.folding(options:[.caseInsensitive],locale:Locale(identifier:"en_GB"))
            if names[key] == nil { names[key] = name }
        }
        return names.values.sorted { $0.compare($1,options:[.caseInsensitive,.numeric],locale:Locale(identifier:"en_GB")) == .orderedAscending }
    }
    public func replace(_ snapshot: [LibraryMeeting]) throws {
        let incoming = Dictionary(uniqueKeysWithValues:snapshot.map { ($0.libraryKey,$0) })
        try database.execute("BEGIN IMMEDIATE")
        do {
            for removed in Set(meetings.keys).subtracting(incoming.keys) { try database.remove(removed) }
            var nextFingerprints: [String:Data] = [:], nextTurns: [String:[MeetingPresentation.Turn]] = [:]
            for meeting in snapshot {
                let hash = Data(SHA256.hash(data:try JSONEncoder().encode(meeting.transcriptItems)))
                nextFingerprints[meeting.libraryKey] = hash
                if fingerprints[meeting.libraryKey] == hash { nextTurns[meeting.libraryKey] = turns[meeting.libraryKey]; continue }
                let grouped = MeetingPresentation.turns(meeting.transcriptItems)
                try database.remove(meeting.libraryKey)
                for (index,turn) in grouped.enumerated() {
                    try database.insert(text:turn.items.map { Self.normalise($0.text) }.joined(separator:" "),meeting:meeting.libraryKey,turn:index)
                }
                nextTurns[meeting.libraryKey] = grouped
            }
            try database.execute("COMMIT")
            fingerprints = nextFingerprints; turns = nextTurns; meetings = incoming
        } catch { try? database.execute("ROLLBACK"); throw error }
    }
    public func search(_ query: String, filter: SearchFilter = .init(), now: Date = Date(), timeZone: TimeZone = .current) throws -> [SearchHit] {
        let query = query.replacingOccurrences(of:"\0",with:" ").trimmingCharacters(in:.whitespacesAndNewlines)
        guard !query.isEmpty, query.count <= 512 else { return [] }
        // All user text is one literal phrase. Quotes/operators cannot become
        // SQL or FTS syntax; the binding is separate from the SQL statement.
        let phrase = "\"" + query.replacingOccurrences(of:"\"",with:"\"\"") + "\""
        let begin = "\u{F0000}" + UUID().uuidString, end = "\u{F0001}" + UUID().uuidString
        let statement = try database.prepare("SELECT meeting, turnIndex, highlight(turns,0,?,?) FROM turns WHERE turns MATCH ?")
        try statement.bind([begin,end,phrase])
        var hits: [SearchHit] = []
        while try statement.next() {
            let key = statement.text(0), index = statement.integer(1)
            guard index >= 0, let meeting = meetings[key], !filter.own || meeting.state.origin == .own,
                  filter.date.contains(meeting.start,now:now,timeZone:timeZone),
                  let turn = turns[key]?.dropFirst(index).first else { continue }
            if let name = filter.speaker {
                guard let speaker = meeting.speakers.first(where:{ $0.id == turn.speaker }), speaker.provenance != .unnamed,
                      speaker.name?.compare(name,options:.caseInsensitive) == .orderedSame else { continue }
            }
            let highlighted = statement.text(2)
            let parsed = Self.unmark(highlighted,begin:begin,end:end)
            // An occurrence is a place. Multiple mentions in a long turn must
            // remain separately seekable, rather than collapsing to one result.
            for (occurrence,span) in parsed.spans.enumerated() {
                var at = 0, position = turn.startMs
                for item in turn.items {
                    let length = Self.normalise(item.text).utf16.count
                    if span.start < at + length { position = item.startMs; break }
                    at += length + 1
                }
                hits.append(.init(meetingKey:key,turn:index,positionMs:position,speaker:turn.speaker,text:parsed.text,spans:parsed.spans,occurrence:occurrence))
            }
        }
        return hits.sorted {
            if $0.meetingKey != $1.meetingKey {
                let a = meetings[$0.meetingKey]?.start ?? .distantPast, b = meetings[$1.meetingKey]?.start ?? .distantPast
                return a == b ? $0.meetingKey < $1.meetingKey : a > b
            }
            return $0.turn == $1.turn ? $0.occurrence < $1.occurrence : $0.turn < $1.turn
        }
    }
    private static func normalise(_ text: String) -> String { text.split(whereSeparator:\.isWhitespace).joined(separator:" ") }
    private static func unmark(_ value: String, begin: String, end: String) -> (text: String, spans: [SearchSpan]) {
        var text = "", spans: [SearchSpan] = [], rest = value[...]
        while let open = rest.range(of:begin) {
            text += rest[..<open.lowerBound]; rest = rest[open.upperBound...]
            guard let close = rest.range(of:end) else { return (value,[]) }
            let start = text.utf16.count; text += rest[..<close.lowerBound]
            spans.append(.init(start:start,length:text.utf16.count - start)); rest = rest[close.upperBound...]
        }
        text += rest; return (text,spans)
    }
}

private enum SearchError: Error { case database(Int32) }
// Confined to SearchIndex. This wrapper also makes deterministic close possible
// from the actor's nonisolated deinitializer under Swift6.
private final class SearchDatabase: @unchecked Sendable {
    let handle: OpaquePointer
    init(cache: URL) throws {
        try FileManager.default.createDirectory(at:cache,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        var info = stat()
        guard lstat(cache.path,&info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid() else { throw POSIXError(.EACCES) }
        guard chmod(cache.path,0o700) == 0 else { throw POSIXError(.EACCES) }
        // Foundation canonicalises /private/var back to the /var alias on
        // macOS. realpath supplies the actual no-symlink path SQLite needs.
        guard let canonical = realpath(cache.path,nil) else { throw POSIXError(.ENOENT) }
        let path = String(cString:canonical) + "/transcripts.sqlite"; free(canonical)
        var existing = stat()
        if lstat(path,&existing) == 0 {
            guard existing.st_mode & S_IFMT == S_IFREG, existing.st_uid == getuid(), existing.st_nlink == 1 else { throw POSIXError(.EACCES) }
        } else if errno != ENOENT { throw POSIXError(.EIO) }
        do { handle = try Self.connect(path) }
        catch SearchError.database(let code) where [SQLITE_CORRUPT,SQLITE_NOTADB].contains(code & 0xff) {
            // A corrupt derived cache can be rebuilt. Only remove this app's
            // exact regular cache files after closing the failed connection.
            for name in [path,path + "-journal"] {
                var file = stat()
                if lstat(name,&file) == 0 {
                    guard file.st_mode & S_IFMT == S_IFREG, file.st_uid == getuid(), file.st_nlink == 1 else { throw POSIXError(.EACCES) }
                    guard unlink(name) == 0 else { throw POSIXError(.EIO) }
                } else if errno != ENOENT { throw POSIXError(.EIO) }
            }
            handle = try Self.connect(path)
        }
    }
    private static func connect(_ path: String) throws -> OpaquePointer {
        var db: OpaquePointer?
        let result = sqlite3_open_v2(path,&db,SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_NOFOLLOW,nil)
        guard result == SQLITE_OK, let db else { if let db { sqlite3_close(db) }; throw SearchError.database(result) }
        _ = chmod(path,0o600); sqlite3_busy_timeout(db,2000)
        let sql = "PRAGMA journal_mode=DELETE; PRAGMA synchronous=NORMAL; PRAGMA secure_delete=ON; PRAGMA trusted_schema=OFF; PRAGMA temp_store=MEMORY; DROP TABLE IF EXISTS turns; CREATE VIRTUAL TABLE turns USING fts5(text,meeting UNINDEXED,turnIndex UNINDEXED,tokenize='unicode61 remove_diacritics 2')"
        let code = sqlite3_exec(db,sql,nil,nil,nil)
        guard code == SQLITE_OK else { sqlite3_close(db); throw SearchError.database(code) }
        return db
    }
    deinit { sqlite3_close(handle) }
    func execute(_ sql: String) throws { let code = sqlite3_exec(handle,sql,nil,nil,nil); guard code == SQLITE_OK else { throw SearchError.database(code) } }
    func prepare(_ sql: String) throws -> SearchStatement { try .init(database:handle,sql:sql) }
    func remove(_ meeting: String) throws { let s = try prepare("DELETE FROM turns WHERE meeting = ?"); try s.bind([meeting]); _ = try s.next() }
    func insert(text: String, meeting: String, turn: Int) throws {
        let s = try prepare("INSERT INTO turns(text,meeting,turnIndex) VALUES(?,?,?)")
        try s.bind([text,meeting,String(turn)]); _ = try s.next()
    }
}
private final class SearchStatement {
    let handle: OpaquePointer
    init(database: OpaquePointer, sql: String) throws {
        var statement: OpaquePointer?
        let code = sqlite3_prepare_v2(database,sql,-1,&statement,nil)
        guard code == SQLITE_OK, let statement else { throw SearchError.database(code) }; handle = statement
    }
    deinit { sqlite3_finalize(handle) }
    func bind(_ values: [String]) throws {
        let transient = unsafeBitCast(-1,to:sqlite3_destructor_type.self)
        for (index,value) in values.enumerated() {
            let data = Array(value.utf8CString)
            let code = data.withUnsafeBufferPointer { sqlite3_bind_text(handle,Int32(index + 1),$0.baseAddress,Int32(data.count - 1),transient) }
            guard code == SQLITE_OK else { throw SearchError.database(code) }
        }
    }
    func next() throws -> Bool {
        let code = sqlite3_step(handle)
        guard [SQLITE_ROW,SQLITE_DONE].contains(code) else { throw SearchError.database(code) }; return code == SQLITE_ROW
    }
    func text(_ column: Int32) -> String {
        guard let bytes = sqlite3_column_text(handle,column) else { return "" }
        return String(decoding:UnsafeBufferPointer(start:bytes,count:Int(sqlite3_column_bytes(handle,column))),as:UTF8.self)
    }
    func integer(_ column: Int32) -> Int { Int(sqlite3_column_int64(handle,column)) }
}
