import Foundation
import CassiniKit

/// A read-only scan. Root and activity are injectable; construction does not touch Music.
public struct LibraryScanner: Sendable {
    public let root: URL
    public let activity: any CaptureActivityProviding
    public init(root: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Music/Cassini"),
                activity: any CaptureActivityProviding = CaptureActivitySnapshot()) {
        self.root = root; self.activity = activity
    }
    public func scan(now: Date = Date()) throws -> LibraryScan {
        let manager = FileManager.default
        do {
            guard try root.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else { throw MetadataError.invalid }
        } catch let error as NSError {
            if error.domain == NSCocoaErrorDomain && [NSFileReadNoSuchFileError, NSFileNoSuchFileError].contains(error.code) { return .init(meetings: [], issues: []) }
            throw error
        }
        let root = root.resolvingSymlinksInPath()
        let children = try manager.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])
        let activity = activity.snapshot()
        var result = LibraryScan(meetings: [], issues: [])
        for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let name = child.lastPathComponent
            let received = name.hasPrefix("Received-")
            guard received || name.hasPrefix("Recording-"), let id = UUID(uuidString: String(name.dropFirst(received ? 9 : 10))) else { continue }
            let folder = child.resolvingSymlinksInPath()
            guard folder.deletingLastPathComponent() == root else { result.issues.append(.unsafePath); continue }
            guard (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            result.meetings.append(read(folder: folder, id: id, received: received, activity: activity[id], now: now))
        }
        result.meetings.sort {
            if $0.start != $1.start { return ($0.start ?? .distantPast) > ($1.start ?? .distantPast) }
            return $0.id.uuidString < $1.id.uuidString
        }
        return result
    }

    private func read(folder: URL, id: UUID, received: Bool, activity: CaptureActivity?, now: Date) -> LibraryMeeting {
        var meeting = LibraryMeeting(id: id, folder: folder, state: .init(origin: received ? .received : .own),
                                     title: nil, start: nil, durationMs: nil, speakers: [], quote: nil, notes: [], audioFiles: [], issues: [])
        var metadata: AppMetadata?
        do {
            let file = try safeFile("meeting.json", in: folder)
            if FileManager.default.fileExists(atPath: file.path) {
                metadata = try readJSON(AppMetadata.self, at: file)
                try metadata?.validate(id: id, received: received)
            }
        } catch { metadata = nil; meeting.issues.append(.invalidMetadata) }
        meeting.title = metadata?.title
        meeting.notes = metadata?.notes ?? []
        meeting.state.transcript = metadata?.transcript.status ?? .none
        meeting.state.etaMinutes = metadata?.etaMinutes
        meeting.state.error = metadata?.error
        var words: [LibraryWord] = []
        var hasTranscriptBody = false
        var embeddedNames: [String: String] = [:]

        if received {
            var original: URL?
            do {
                if let name = metadata?.received?.originalName { original = try safeFile(name, in: folder) }
                else {
                    let candidates = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).filter { $0.pathExtension == "opus" }
                    if candidates.count == 1 { original = try safeFile(candidates[0].lastPathComponent, in: folder) }
                }
                guard let original else { throw MetadataError.invalid }
                let file = try CassiniReader.read(contentsOf: original)
                meeting.audioFiles = [original]
                if meeting.title == nil { meeting.title = file.manifest?.meeting.title }
                meeting.start = file.manifest.flatMap { recordingDate($0.meeting.createdAtUtc) }
                if case .success(let digest)? = file.audioDigest { meeting.durationMs = Int64(digest.durationMs) }
                else { meeting.durationMs = file.manifest.map { Int64($0.audio.durationMs) } }
                for speaker in file.manifest?.speakers ?? [] { embeddedNames[speaker.id] = speaker.label }
                if metadata?.transcript.reference?.kind != "sidecar" {
                    let selected = metadata?.transcript.reference?.transcriptId.flatMap { requested in file.transcripts.first { $0.entry.id == requested } } ?? file.defaultTranscript
                    if let body = selected?.load.transcript, ![.invalidCassiniMetadata, .staleAudio, .unknownCassiniFormat].contains(file.state) {
                        hasTranscriptBody = true
                        words = body.items.map { .init(speaker: $0.speaker, startMs: Int64($0.startMs), endMs: Int64($0.endMs), text: $0.text) }
                        if metadata == nil || meeting.state.transcript == .none { meeting.state.transcript = .done }
                    } else if selected != nil || file.state == .invalidCassiniMetadata || file.state == .staleAudio {
                        damage(&meeting)
                    }
                }
            } catch { meeting.issues.append(.invalidAudio) }
            if meeting.start == nil, let imported = metadata?.received?.importedAtMs { meeting.start = Date(timeIntervalSince1970: Double(imported) / 1000) }
        } else {
            let capture = capture(folder: folder, id: id)
            meeting.issues += capture.issues
            if meeting.title == nil { meeting.title = capture.title }
            meeting.start = capture.start
            meeting.audioFiles = capture.files
            meeting.durationMs = capture.endMs
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

        if let reference = metadata?.transcript.reference, reference.kind == "sidecar" {
            do {
                let body = try readJSON(LibraryWords.self, at: safeFile(reference.file, in: folder), limit: 64 * 1024 * 1024)
                try body.validate(); words = body.items; hasTranscriptBody = true
                if meeting.state.transcript == .none { meeting.state.transcript = .done }
            } catch { damage(&meeting); words = [] }
        }
        if meeting.state.transcript == .done && !hasTranscriptBody { damage(&meeting) }
        if meeting.state.transcript == .damaged { words = [] }
        var ids: [String] = []
        var first: [String: (Int64, Int)] = [:]
        for (index, word) in words.enumerated() {
            if first[word.speaker] == nil { ids.append(word.speaker); first[word.speaker] = (word.startMs, index) }
            else if word.startMs < first[word.speaker]!.0 { first[word.speaker] = (word.startMs, index) }
        }
        ids.sort { first[$0]!.0 == first[$1]!.0 ? first[$0]!.1 < first[$1]!.1 : first[$0]!.0 < first[$1]!.0 }
        for speaker in metadata?.speakers ?? [] where !ids.contains(speaker.id) { ids.append(speaker.id) }
        for speaker in embeddedNames.keys.sorted() where !ids.contains(speaker) { ids.append(speaker) }
        let overrides = Dictionary(uniqueKeysWithValues: (metadata?.speakers ?? []).map { ($0.id, $0) })
        meeting.speakers = ids.enumerated().map { index, id in
            if let speaker = overrides[id] { return .init(id: id, name: speaker.name, provenance: speaker.provenance, colourIndex: speaker.colourIndex) }
            return .init(id: id, name: embeddedNames[id], provenance: embeddedNames[id] == nil ? .unnamed : nil, colourIndex: index)
        }
        meeting.quote = metadata?.quoteOverride ?? defaultQuote(words)
        return meeting
    }

    private func damage(_ meeting: inout LibraryMeeting) {
        meeting.state.transcript = .damaged; meeting.state.etaMinutes = nil
        if meeting.state.error == nil { meeting.state.error = .init(id: "transcript-damaged") }
        meeting.issues.append(.invalidTranscript)
    }
    private struct Capture {
        var title: String?; var start: Date?; var endMs: Int64?; var files: [URL] = []
        var unfinalized = false; var interrupted = false; var issues: [LibraryReadIssue] = []
    }
    private struct Manifest: Decodable {
        let version: Int; let id: UUID; let title: String; let createdAt: String; let state: String; let problemKind: String?
        let tracks: [Track]
        struct Track: Decodable { let file: String; let sampleRate: Int; let channels: Int; let startOffsetMs: Double?; let gapFrames: UInt64? }
    }
    private func capture(folder: URL, id: UUID) -> Capture {
        var result = Capture()
        do {
            let manifest = try readJSON(Manifest.self, at: safeFile("session.json", in: folder))
            guard manifest.version == 1, manifest.id == id, manifest.tracks.count <= 64,
                  ["recording", "completed", "interrupted"].contains(manifest.state) else { throw MetadataError.invalid }
            result.title = manifest.title; result.start = recordingDate(manifest.createdAt)
            result.unfinalized = manifest.state == "recording"
            result.interrupted = manifest.state == "interrupted" || manifest.problemKind == "gap" || manifest.tracks.contains { ($0.gapFrames ?? 0) > 0 }
            var ends: [Double] = []
            for track in manifest.tracks {
                do {
                    guard track.file.hasPrefix("track-"), track.file.hasSuffix(".wav") else { throw MetadataError.invalid }
                    let url = try safeFile(track.file, in: folder)
                    let wave = try Self.wave(url)
                    guard wave.rate == track.sampleRate, wave.channels == track.channels else { throw MetadataError.invalid }
                    result.files.append(url)
                    let length = Double(wave.frames) / Double(wave.rate) * 1000
                    if let start = track.startOffsetMs, start.isFinite, (0...86_400_000).contains(start) { ends.append(start + length) }
                    else { ends.append(length); if wave.frames > 0 { result.issues.append(.unknownStartOffset) } }
                } catch { result.issues.append(.invalidAudio); result.interrupted = true }
            }
            result.endMs = Int64((ends.max() ?? 0).rounded(.down))
        } catch {
            result.issues.append(.invalidCapture); result.interrupted = true
            let candidates = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            var lengths: [Double] = []
            for url in candidates.filter({ $0.lastPathComponent.hasPrefix("track-") && $0.pathExtension == "wav" }).prefix(64) {
                if let safe = try? safeFile(url.lastPathComponent, in: folder), let wave = try? Self.wave(safe) {
                    result.files.append(safe); lengths.append(Double(wave.frames) / Double(wave.rate) * 1000)
                }
            }
            // D3: assumed zero is display-only, never persisted or used for playback alignment.
            result.endMs = Int64((lengths.max() ?? 0).rounded(.down))
            if !lengths.isEmpty { result.issues.append(.unknownStartOffset) }
        }
        return result
    }
    private static func wave(_ url: URL) throws -> (rate: Int, channels: Int, frames: UInt64) {
        let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
        let size = try file.seekToEnd(); try file.seek(toOffset: 0)
        let data = try file.read(upToCount: 44) ?? Data()
        guard data.count == 44, size >= 44, size <= UInt64(UInt32.max) + 8,
              data[0..<4] == Data("RIFF".utf8), data[8..<16] == Data("WAVEfmt ".utf8), data[36..<40] == Data("data".utf8) else { throw MetadataError.invalid }
        func n16(_ at: Int) -> Int { data.withUnsafeBytes { Int($0.loadUnaligned(fromByteOffset: at, as: UInt16.self).littleEndian) } }
        func n32(_ at: Int) -> Int { data.withUnsafeBytes { Int($0.loadUnaligned(fromByteOffset: at, as: UInt32.self).littleEndian) } }
        let rate = n32(24), channels = n16(22)
        guard n32(16) == 16, n16(20) == 1, n16(34) == 16, (8000...192000).contains(rate), (1...2).contains(channels),
              n16(32) == channels * 2, n32(28) == rate * channels * 2 else { throw MetadataError.invalid }
        return (rate, channels, (size - 44) / UInt64(channels * 2))
    }
}
private struct LibraryWords: Decodable {
    let items: [LibraryWord]
    func validate() throws {
        guard items.allSatisfy({ !$0.speaker.isEmpty && $0.startMs >= 0 && $0.endMs >= $0.startMs && $0.endMs <= AppMetadata.safe }) else { throw MetadataError.invalid }
    }
}
private struct LibraryWord: Decodable {
    let speaker: String; let startMs: Int64; let endMs: Int64; let text: String
}
private func defaultQuote(_ words: [LibraryWord]) -> MeetingQuote? {
    struct Turn { var speaker: String; var start: Int64; var end: Int64; var text: [String] }
    var turns: [Turn] = []
    for word in words {
        if turns.last?.speaker == word.speaker {
            turns[turns.count - 1].start = min(turns.last!.start, word.startMs)
            turns[turns.count - 1].end = max(turns.last!.end, word.endMs)
            turns[turns.count - 1].text.append(word.text)
        } else { turns.append(Turn(speaker: word.speaker, start: word.startMs, end: word.endMs, text: [word.text])) }
    }
    let eligible = turns.enumerated().filter { $0.element.start < 600000 }
    let selected = eligible.sorted {
        let a = $0.element, b = $1.element
        if a.end - a.start != b.end - b.start { return a.end - a.start > b.end - b.start }
        if a.start != b.start { return a.start < b.start }
        return $0.offset < $1.offset
    }.first?.element
    return selected.map { MeetingQuote(atMs: $0.start, text: $0.text.joined(separator: " ")) }
}
