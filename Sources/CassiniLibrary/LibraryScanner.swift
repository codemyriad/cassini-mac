// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Darwin
import CassiniKit

/// Read-only R1–R10 derivation. Root/activity are injected. UI clients use
/// scanInBackground; watcher folder URLs select an incremental scan.
public struct LibraryScanner: Sendable {
    public let root: URL
    public let activity: any CaptureActivityProviding
    let cache = LibraryFileCache()
    private let snapshot = Snapshot()
    private final class Snapshot: @unchecked Sendable {
        let lock = NSLock()
        var root: URL?
        var meetings: [URL: LibraryMeeting] = [:]
        var files: [URL: Set<URL>] = [:]
        var issues: [URL: [LibraryReadIssue]] = [:]
    }
    public init(root: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Music/Cassini"),
                activity: any CaptureActivityProviding = CaptureActivitySnapshot()) {
        self.root = URL(fileURLWithPath: root.standardizedFileURL.path, isDirectory: false); self.activity = activity
    }
    public func scan(now: Date = Date()) throws -> LibraryScan { try scan(affected: nil, now: now) }
    public func scan(affected: URL?, now: Date = Date()) throws -> LibraryScan {
        snapshot.lock.lock(); defer { snapshot.lock.unlock() }
        let original = try pathInfo(root)
        if original == nil {
            snapshot.root = root; snapshot.meetings = [:]; snapshot.files = [:]; snapshot.issues = [:]
            cache.prune(keeping: [])
            return .init(meetings: [], issues: [])
        }
        let resolved = try physicalURL(root)
        guard let info = try pathInfo(resolved), info.st_mode & S_IFMT == S_IFDIR else { throw MetadataError.invalid }
        let activities = activity.snapshot()
        let incremental = affected.flatMap { url -> URL? in
            guard snapshot.root == resolved, (try? physicalURL(url.deletingLastPathComponent()).path) == resolved.path,
                  Self.identity(url.lastPathComponent) != nil else { return nil }
            return URL(fileURLWithPath: resolved.path + "/" + url.lastPathComponent, isDirectory: false)
        }
        let children: [URL]
        if let incremental {
            children = [incremental]
            snapshot.meetings.removeValue(forKey: incremental); snapshot.files.removeValue(forKey: incremental); snapshot.issues.removeValue(forKey: incremental)
        } else {
            children = try FileManager.default.contentsOfDirectory(at: resolved, includingPropertiesForKeys: nil).map { URL(fileURLWithPath: resolved.path + "/" + $0.lastPathComponent, isDirectory: false) }
            snapshot.meetings = [:]; snapshot.files = [:]; snapshot.issues = [:]
        }
        for folder in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard let (id, received) = Self.identity(folder.lastPathComponent) else { continue }
            guard let info = try? pathInfo(folder) else { continue }
            if info.st_mode & S_IFMT == S_IFLNK { snapshot.issues[folder] = [.unsafePath]; continue }
            guard info.st_mode & S_IFMT == S_IFDIR else { continue }
            var seen = Set<URL>()
            if let meeting = read(folder: folder, id: id, received: received, activity: activities[id], now: now, seen: &seen) {
                snapshot.meetings[folder] = meeting
            }
            snapshot.files[folder] = seen
        }
        snapshot.root = resolved
        cache.prune(keeping: Set(snapshot.files.values.flatMap { $0 }))
        return .init(meetings: snapshot.meetings.values.sorted(by: Self.ordered), issues: snapshot.issues.values.flatMap { $0 })
    }
    public func scanInBackground(affected: URL? = nil, now: Date = Date()) async throws -> LibraryScan {
        try await Task.detached(priority: .userInitiated) { try scan(affected: affected, now: now) }.value
    }
    static func identity(_ name: String) -> (UUID, Bool)? {
        let received = name.hasPrefix("Received-")
        guard received || name.hasPrefix("Recording-") else { return nil }
        let text = String(name.dropFirst(received ? 9 : 10))
        guard let id = UUID(uuidString: text), id.uuidString.lowercased() == text else { return nil }
        return (id, received)
    }
    private static func ordered(_ a: LibraryMeeting, _ b: LibraryMeeting) -> Bool {
        if let x = a.start, let y = b.start { return x == y ? identityOrdered(a, b) : x > y }
        if a.start != nil || b.start != nil { return a.start != nil }
        let x = (a.title ?? "").folding(options: .caseInsensitive, locale: Locale(identifier: "en_GB"))
        let y = (b.title ?? "").folding(options: .caseInsensitive, locale: Locale(identifier: "en_GB"))
        if x != y { return x < y }
        if a.title != b.title { return (a.title ?? "") < (b.title ?? "") }
        return identityOrdered(a, b)
    }
    private static func identityOrdered(_ a: LibraryMeeting, _ b: LibraryMeeting) -> Bool {
        a.id == b.id ? a.libraryKey < b.libraryKey : a.id.uuidString < b.id.uuidString
    }
    private func json<Value: Decodable>(_ type: Value.Type, at url: URL, limit: Int = 1_048_576,
                                       seen: inout Set<URL>) throws -> Value {
        seen.insert(url)
        return try cache.read(url) { try decodeJSON(type, data: regularData($0, limit: limit)) }
    }
    private func read(folder: URL, id: UUID, received: Bool, activity: CaptureActivity?, now: Date,
                      seen: inout Set<URL>) -> LibraryMeeting? {
        var meeting = LibraryMeeting(id: id, folder: folder, state: .init(origin: received ? .received : .own),
                                     title: nil, start: nil, durationMs: nil, speakers: [], quote: nil, notes: [], audioFiles: [], issues: [])
        var metadata: AppMetadata?
        do {
            let url = try safeFile("meeting.json", in: folder); seen.insert(url)
            if try pathInfo(url) != nil {
                metadata = try cache.read(url) { try AppMetadata.parse(regularData($0, limit: 1_048_576)) }
                try metadata?.validate(id: id, received: received)
            }
        } catch MetadataError.unsupportedVersion {
            meeting.metadataReadOnly = true; meeting.issues.append(.unsupportedVersion)
        } catch { metadata = nil; meeting.issues.append(.invalidMetadata) }
        guard !received || metadata != nil else { return nil } // R1.4: import not committed.
        meeting.notes = metadata?.notes ?? []
        if let value = metadata?.received {
            meeting.received = .init(originalName:value.originalName,originalFolderName:value.originalFolderName,sha256:value.sha256,importedAtMs:value.importedAtMs)
        }
        meeting.state.transcript = metadata?.transcript.status ?? .none
        meeting.state.etaMinutes = metadata?.etaMinutes
        meeting.state.error = metadata?.error
        var titleCandidates: [String?] = [metadata?.title]
        var file: CassiniFile?
        var original: URL?
        var embeddedNames: [String: String] = [:]
        if received, let receivedMetadata = metadata?.received {
            do {
                let url = try safeFile(receivedMetadata.originalName, in: folder); original = url; seen.insert(url)
                file = try cache.read(url) { try CassiniReader.read(regularData($0)) }
                if let file {
                    titleCandidates += [file.manifest?.meeting.title, file.tags?["TITLE"]]
                    meeting.start = file.manifest.flatMap { recordingDate($0.meeting.createdAtUtc) }
                    if case .success(let digest)? = file.audioDigest {
                        meeting.durationMs = Int64(digest.durationMs); meeting.audioFiles = [url]
                    } else { meeting.issues.append(.invalidAudio) }
                    if file.state == .unknownCassiniFormat { meeting.issues.append(.unsupportedVersion) }
                    for speaker in file.manifest?.speakers ?? [] { embeddedNames[speaker.id] = speaker.label }
                }
            } catch { meeting.issues.append(.invalidAudio) }
            titleCandidates.append((receivedMetadata.originalName as NSString).deletingPathExtension)
            if meeting.start == nil { meeting.start = Date(timeIntervalSince1970: Double(receivedMetadata.importedAtMs) / 1000) }
        } else {
            let capture = capture(folder: folder, id: id, seen: &seen)
            meeting.issues += capture.issues; meeting.captureSource = capture.source; meeting.captureFinalized = capture.finalized
            titleCandidates.append(capture.title)
            meeting.start = capture.start; meeting.audioFiles = capture.files; meeting.audioTracks = capture.tracks; meeting.durationMs = capture.endMs
            switch activity {
            case .recording?: meeting.state.lifecycle = .recording
            case .saving?: meeting.state.lifecycle = .saving
            case nil: meeting.state.lifecycle = .saved
            }
            if capture.interrupted || (capture.unfinalized && activity == nil) { meeting.state.interruptedAtMs = capture.endMs }
            if let start = meeting.start, meeting.state.lifecycle == .recording {
                meeting.state.liveMs = max(0, Int64((now.timeIntervalSince(start) * 1000).rounded(.down)))
            }
        }
        meeting.state.audioAvailable = !meeting.audioFiles.isEmpty
        meeting.title = titleCandidates.compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty } ?? "Untitled meeting"

        var words: [LibraryTranscriptItem] = []
        var readable = false
        var bodyPresent = false
        do {
            if let reference = metadata?.transcript.reference {
                bodyPresent = true
                if received {
                    guard let file, ![.staleAudio, .unknownCassiniFormat].contains(file.state),
                          case .success? = file.audioDigest else { throw MetadataError.invalid }
                }
                if reference.kind == "sidecar" {
                    let body = try json(LibraryWords.self, at: safeFile(reference.file, in: folder), limit: 64 * 1024 * 1024, seen: &seen)
                    try body.validate(); words = body.items; meeting.transcriptLanguage = body.language; readable = true
                } else {
                    guard received, reference.file == metadata?.received?.originalName, original != nil, let file,
                          ![.invalidCassiniMetadata, .staleAudio, .unknownCassiniFormat].contains(file.state),
                          case .success? = file.audioDigest else { throw MetadataError.invalid }
                    let selected: (entry: TranscriptEntry, load: TranscriptLoad)?
                    if let requested = reference.transcriptId { selected = file.transcripts.first { $0.entry.id == requested } }
                    else { selected = file.defaultTranscript }
                    guard let body = selected?.load.transcript else { throw MetadataError.invalid }
                    words = body.items.map { .init(speaker: $0.speaker, startMs: Int64($0.startMs), endMs: Int64($0.endMs), text: $0.text) }
                    meeting.transcriptLanguage = body.language
                    readable = true
                }
            } else if metadata == nil {
                let url = try safeFile("transcript.json", in: folder)
                if try pathInfo(url) != nil {
                    bodyPresent = true
                    let body = try json(LibraryWords.self, at: url, limit: 64 * 1024 * 1024, seen: &seen)
                    try body.validate(); words = body.items; readable = true
                }
            }
        } catch { words = []; meeting.issues.append(.invalidTranscript) }
        if metadata == nil { meeting.state.transcript = readable ? .done : (bodyPresent ? .damaged : .none) }
        switch meeting.state.transcript {
        case .queued, .running: break // R3: missing body means no words yet, not damage.
        case .failed:
            if meeting.state.error == nil { meeting.state.error = .init(id: "transcribe-failed", action: "Try again") }
        case .done: if !readable { damage(&meeting) }
        case .damaged: damage(&meeting)
        case .none: break // Never promote an explicit none just because a body exists.
        }
        if ![.queued, .running].contains(meeting.state.transcript) { meeting.state.etaMinutes = nil }
        if meeting.state.transcript == .damaged { words = [] }
        let sorted = words.enumerated().sorted {
            $0.element.startMs == $1.element.startMs ? $0.offset < $1.offset : $0.element.startMs < $1.element.startMs
        }.map(\.element)
        meeting.transcriptItems = sorted
        var ids: [String] = []
        for word in sorted where !ids.contains(word.speaker) { ids.append(word.speaker) }
        let overrides = Dictionary(uniqueKeysWithValues: (metadata?.speakers ?? []).map { ($0.id, $0) })
        meeting.speakers = ids.enumerated().map { index, id in
            let override = overrides[id]
            let label = embeddedNames[id]?.trimmingCharacters(in: .whitespacesAndNewlines)
            let embedded = label.flatMap { $0.isEmpty || $0.range(of: "^Speaker [0-9]+$", options: .regularExpression) != nil ? nil : $0 }
            let name = override?.name ?? embedded
            return .init(id: id, name: name, provenance: override?.name != nil ? override?.provenance : (name == nil ? .unnamed : nil), colourIndex: index)
        }
        if [.done, .queued, .running].contains(meeting.state.transcript), !words.isEmpty {
            meeting.quote = normalizedOverride(metadata?.quoteOverride) ?? defaultQuote(sorted)
        }
        return meeting
    }
    private func damage(_ meeting: inout LibraryMeeting) {
        meeting.state.transcript = .damaged; meeting.state.etaMinutes = nil
        if meeting.state.error?.action == nil { meeting.state.error = .init(id: "transcript-damaged") }
        if !meeting.issues.contains(.invalidTranscript) { meeting.issues.append(.invalidTranscript) }
    }
    private struct Capture {
        var source: String?; var title: String?; var start: Date?; var endMs: Int64?; var files: [URL] = []
        var tracks: [LibraryAudioTrack] = []
        var unfinalized = false; var finalized = false; var interrupted = false; var issues: [LibraryReadIssue] = []
    }
    private struct Manifest: Decodable {
        let version: Int; let id: UUID; let title: String?; let createdAt: String?; let state: String; let problemKind: String?
        var tracks: [Track]
        var source: String?
        enum CodingKeys: CodingKey { case version, id, title, createdAt, state, problemKind, tracks }
        struct Track: Decodable {
            let file: String?; let sampleRate: Int?; let channels: Int?; var startOffsetMs: DisplayOffset?; let gapFrames: Double?
            enum CodingKeys: CodingKey { case file, sampleRate, channels, startOffsetMs, gapFrames }
            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                file = try? c.decode(String.self, forKey: .file)
                sampleRate = try? c.decode(Int.self, forKey: .sampleRate); channels = try? c.decode(Int.self, forKey: .channels)
                startOffsetMs = nil; gapFrames = try? c.decode(Double.self, forKey: .gapFrames)
            }
        }
        static func parse(_ data: Data) throws -> Self {
            let raw = try JSONParser.parse(data)
            var manifest = try JSONDecoder().decode(Self.self, from: data)
            manifest.source = raw["source"]?.string
            if let tracks = raw["tracks"]?.array {
                for index in manifest.tracks.indices { manifest.tracks[index].startOffsetMs = DisplayOffset(tracks[index]["startOffsetMs"]) }
            }
            return manifest
        }
    }
    private func capture(folder: URL, id: UUID, seen: inout Set<URL>) -> Capture {
        var result = Capture()
        do {
            let session = try safeFile("session.json", in: folder); seen.insert(session)
            let manifest = try cache.read(session) { try Manifest.parse(regularData($0, limit: 1_048_576)) }
            if manifest.version > 1 { result.issues.append(.unsupportedVersion) }
            guard manifest.version == 1, manifest.id == id, manifest.tracks.count <= 64,
                  ["recording", "completed", "interrupted"].contains(manifest.state) else { throw MetadataError.invalid }
            result.source = manifest.source; result.title = manifest.title; result.start = manifest.createdAt.flatMap(recordingDate)
            result.unfinalized = manifest.state == "recording"; result.finalized = manifest.state != "recording"
            result.interrupted = manifest.state == "interrupted" || manifest.problemKind == "gap" || manifest.tracks.contains { ($0.gapFrames ?? 0) > 0 }
            var ends: [Int64] = []
            for track in manifest.tracks {
                do {
                    guard let name = track.file, name.hasPrefix("track-"), name.hasSuffix(".wav") else { throw MetadataError.invalid }
                    let url = try safeFile(name, in: folder)
                    let wave = try Self.wave(url)
                    guard wave.rate == track.sampleRate, wave.channels == track.channels else { throw MetadataError.invalid }
                    result.files.append(url)
                    result.tracks.append(.init(url: url, startOffsetMs: track.startOffsetMs?.milliseconds, frameCount: wave.frames))
                    if track.startOffsetMs == nil { result.issues.append(.unknownStartOffset) }
                    ends.append((track.startOffsetMs ?? .zero).end(frames: wave.frames, rate: wave.rate))
                } catch { result.issues.append(.invalidAudio) } // R4: a completed session is trusted.
            }
            result.endMs = ends.max() // R5: no counted track is unknown, never zero.
        } catch {
            result.issues.append(.invalidCapture); result.interrupted = true
            let candidates = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            var lengths: [Int64] = []
            for url in candidates.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where url.lastPathComponent.hasPrefix("track-") && url.pathExtension == "wav" {
                if let safe = try? safeFile(url.lastPathComponent, in: folder), let wave = try? Self.wave(safe) {
                    result.files.append(safe); result.tracks.append(.init(url: safe, startOffsetMs: nil, frameCount: wave.frames)); lengths.append(Int64(wave.frames * 1000 / UInt64(wave.rate)))
                }
            }
            result.endMs = lengths.max()
            if !lengths.isEmpty { result.issues.append(.unknownStartOffset) }
        }
        return result
    }
    private static func wave(_ url: URL) throws -> (rate: Int, channels: Int, frames: UInt64) {
        let (fd, key) = try openRegular(url); defer { Darwin.close(fd) }
        let data = try FileHandle(fileDescriptor: fd, closeOnDealloc: false).read(upToCount: 44) ?? Data()
        guard data.count == 44, key.size >= 44, UInt64(key.size) <= UInt64(UInt32.max) + 8,
              data[0..<4] == Data("RIFF".utf8), data[8..<16] == Data("WAVEfmt ".utf8), data[36..<40] == Data("data".utf8) else { throw MetadataError.invalid }
        func n16(_ at: Int) -> Int { data.withUnsafeBytes { Int($0.loadUnaligned(fromByteOffset: at, as: UInt16.self).littleEndian) } }
        func n32(_ at: Int) -> Int { data.withUnsafeBytes { Int($0.loadUnaligned(fromByteOffset: at, as: UInt32.self).littleEndian) } }
        let rate = n32(24), channels = n16(22)
        guard n32(16) == 16, n16(20) == 1, n16(34) == 16, (8000...192000).contains(rate), (1...2).contains(channels),
              n16(32) == channels * 2, n32(28) == rate * channels * 2 else { throw MetadataError.invalid }
        return (rate, channels, UInt64(key.size - 44) / UInt64(channels * 2))
    }
}
private struct LibraryWords: Decodable {
    let items: [LibraryTranscriptItem]
    let language: String?
    enum CodingKeys: CodingKey { case items, language }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy:CodingKeys.self)
        items = try values.decode([LibraryTranscriptItem].self,forKey:.items)
        language = try? values.decode(String.self,forKey:.language)
    }
    func validate() throws {
        guard items.allSatisfy({ !$0.speaker.isEmpty && $0.startMs >= 0 && $0.endMs >= $0.startMs && $0.endMs <= AppMetadata.safe }) else { throw MetadataError.invalid }
    }
}
public struct LibraryTranscriptItem: Codable, Equatable, Sendable {
    public let speaker: String; public let startMs: Int64; public let endMs: Int64; public let text: String
    public init(speaker: String, startMs: Int64, endMs: Int64, text: String) {
        self.speaker = speaker; self.startMs = startMs; self.endMs = endMs; self.text = text
    }
}
private func collapsed(_ text: String) -> String { text.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
private func normalizedOverride(_ quote: MeetingQuote?) -> MeetingQuote? {
    guard let quote else { return nil }
    var text = collapsed(quote.text)
    if (text.hasPrefix("\"") && text.hasSuffix("\"")) || (text.hasPrefix("“") && text.hasSuffix("”")) {
        text = collapsed(String(text.dropFirst().dropLast()))
    }
    return text.isEmpty ? nil : MeetingQuote(atMs: quote.atMs, text: text)
}
private func defaultQuote(_ words: [LibraryTranscriptItem]) -> MeetingQuote? {
    struct Turn { var speaker: String; var start: Int64; var end: Int64; var text: [String]; var ordinal: Int }
    var turns: [Turn] = []
    for (index, word) in words.enumerated() {
        if turns.last?.speaker == word.speaker {
            turns[turns.count - 1].end = word.endMs
            turns[turns.count - 1].text.append(word.text)
        } else { turns.append(.init(speaker: word.speaker, start: word.startMs, end: word.endMs, text: [word.text], ordinal: index)) }
    }
    let selected = turns.filter { $0.start < 600000 }.sorted {
        if $0.end - $0.start != $1.end - $1.start { return $0.end - $0.start > $1.end - $1.start }
        return $0.start == $1.start ? $0.ordinal < $1.ordinal : $0.start < $1.start
    }.first
    guard let selected else { return nil }
    let text = collapsed(selected.text.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.joined(separator: " "))
    return text.isEmpty ? nil : MeetingQuote(atMs: selected.start, text: text)
}
