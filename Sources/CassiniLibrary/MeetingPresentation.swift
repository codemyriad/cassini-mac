// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import CassiniKit

/// R12: sum real item durations; distribute remaining percentage points by
/// largest remainder, with first-speaking order breaking ties.
public enum MeetingPresentation {
    /// D47: preserve the stored excerpt verbatim. The row owns its decorative
    /// bookends; normalization belongs to transcript production/migration.
    public static func pullQuote(_ quote: MeetingQuote) -> String { quote.text }
    public static func shares(_ meeting: LibraryMeeting) -> [String: Int] {
        let durations = Dictionary(grouping: meeting.transcriptItems, by: \.speaker)
            .mapValues { $0.reduce(0.0) { $0 + max(0, Double($1.endMs - $1.startMs)) } }
        let total = durations.values.reduce(0, +)
        guard total > 0 else { return Dictionary(uniqueKeysWithValues: meeting.speakers.map { ($0.id, 0) }) }
        let values = meeting.speakers.map { ($0.id, 100 * durations[$0.id, default: 0] / total) }
        var result = Dictionary(uniqueKeysWithValues: values.map { ($0.0, Int($0.1.rounded(.down))) })
        let remainder = max(0, 100 - result.values.reduce(0, +))
        let order = values.enumerated().sorted {
            let a = $0.element.1 - floor($0.element.1), b = $1.element.1 - floor($1.element.1)
            return a == b ? $0.offset < $1.offset : a > b
        }
        for value in order.prefix(remainder) { result[value.element.0, default: 0] += 1 }
        return result
    }
    public struct Turn: Identifiable, Sendable {
        public let id: Int
        public let speaker: String
        public var items: [LibraryTranscriptItem]
        /// Viewer row bounds, including its inline chips; child turns retain their own bounds.
        public internal(set) var startMs: Int64
        public internal(set) var endMs: Int64
        /// Displayed-item ranges of the consecutive runs rejoined into this turn.
        public internal(set) var fragments: [Range<Int>]
        /// Audible spans of each fragment's words (zero-length words excluded).
        var pools: [[Span]]
        /// D84: short turns of other speakers shown inline, each after
        /// the displayed item `after`; `host` is set on a turn shown inside another one.
        public internal(set) var asides: [(after: Int, turn: Int)] = []
        public internal(set) var host: Int?
        /// Speakers whose words overlap this turn's words by at least 150 ms.
        public internal(set) var over: [String] = []
        /// The viewer hides a repeated name within 60 seconds, retaining its clock.
        public internal(set) var continuation = false
        public internal(set) var crosstalk = false
    }
    typealias Span = (start: Int64, end: Int64)
    /// D84: every transcript surface uses the viewer's word-only rendering pipeline.
    /// These constants remain the bounds used by the sweep differential regressions.
    public static let seamGapMs: Int64 = 400
    public static let touchToleranceMs: Int64 = 20
    public static let asideMaxMs: Int64 = 2000
    public static let sideGapMs: Int64 = 500
    public static let overlapMinMs: Int64 = 150
    /// Union of audible word intervals, excluding zero durations.
    static func spans(_ words: [LibraryTranscriptItem]) -> [Span] {
        var out: [Span] = []
        for w in words.sorted(by:{ $0.startMs < $1.startMs }) where w.endMs > w.startMs {
            if let last = out.last, w.startMs <= last.end { out[out.count-1].end = max(last.end,w.endMs) } else { out.append((w.startMs,w.endMs)) }
        }
        return out
    }
    static func union(_ pools: [[Span]]) -> [Span] {
        var out: [Span] = []
        for span in pools.flatMap({ $0 }).sorted(by:{ $0.start < $1.start }) {
            if let last = out.last, span.start <= last.end { out[out.count-1].end = max(last.end,span.end) } else { out.append(span) }
        }
        return out
    }
    /// Whether a meeting update changes what its turns are prepared from: the words, the speakers,
    /// or the speakers' gap ranges (D63 #2; a gap-only manifest update re-splits turns).
    public static func turnInputsChanged(from old: LibraryMeeting, to new: LibraryMeeting) -> Bool {
        new.wordEndsBoundedByAudio != old.wordEndsBoundedByAudio || new.transcriptItems != old.transcriptItems || new.speakers.map(\.id) != old.speakers.map(\.id) || new.speakerGaps != old.speakerGaps
    }
    public static func turns(_ items: [LibraryTranscriptItem], gaps: SpeakerGapRanges.Ranges = [:], endsBoundedByAudio: Bool = false) -> [Turn] {
        (try? turns(items,gaps:gaps,endsBoundedByAudio:endsBoundedByAudio,cancellable:false)) ?? []
    }
    /// The same, for a caller off the main actor: with `cancellable`, a cancelled task stops
    /// at the next step with CancellationError (#118 review: long transcripts prepare off the
    /// main actor, and a superseded preparation never finishes).
    /// D63 #2: with `gaps` (SpeakerGapRanges), consecutive words of one speaker split where one of
    /// that speaker's gap ranges lies between their midpoints, and the 400 ms rejoin never joins
    /// across one; pauses inside presence still join.
    public static func turns(_ items: [LibraryTranscriptItem], gaps: SpeakerGapRanges.Ranges = [:], endsBoundedByAudio: Bool = false, cancellable: Bool) throws -> [Turn] {
        var boundaries: Set<Int> = []
        var previous: [String:LibraryTranscriptItem] = [:]
        for (i,item) in items.enumerated() {
            if let before = previous[item.speaker], SpeakerGapRanges.splits(before,item,gaps) { boundaries.insert(i) }
            previous[item.speaker] = item
        }
        let input = items.map { TranscriptRendering.Word(speaker:$0.speaker,startMs:$0.startMs,endMs:$0.endMs,text:$0.text,lowConfidenceSpeaker:$0.lowConfidenceSpeaker) }
        let rendered = try TranscriptRendering.render(input,endsBoundedByAudio:endsBoundedByAudio,breakBefore:boundaries,cancellable:cancellable,separates:{ SpeakerGapRanges.splits(items[$0],items[$1],gaps) })
        func item(_ i: Int) -> LibraryTranscriptItem {
            let w = rendered.words[i]
            return .init(speaker:w.speaker,startMs:w.startMs,endMs:w.endMs,text:w.text,lowConfidenceSpeaker:w.lowConfidenceSpeaker)
        }
        var result: [Turn] = [], firstID: [Int:Int] = [:]
        var rowByID: [Int:TranscriptRendering.Row] = [:]
        // Expand a visible run to its readable paragraphs, while retaining hidden child turns
        // as addressable listening targets. IDs continue to be array indices.
        let rowsByRun = Dictionary(grouping:rendered.rows,by:\.turnID)
        for run in rendered.runs {
            if cancellable { try Task.checkCancellation() }
            firstID[run.id] = result.count
            let rows = rowsByRun[run.id] ?? []
            if run.host != nil {
                let blocks = run.blocks.map { rendered.blocks[$0] }
                let indices = blocks.flatMap(\.wordIndices)
                var at = 0
                let ranges = blocks.map { b -> Range<Int> in defer { at += b.wordIndices.count }; return at..<(at+b.wordIndices.count) }
                result.append(.init(id:result.count,speaker:run.speaker,items:indices.map(item),startMs:run.startMs,endMs:run.endMs,fragments:ranges,pools:blocks.map { spans($0.wordIndices.map(item)) },over:run.over))
            } else {
                for row in rows {
                    let own = row.members.filter { $0.kind == "words" }
                    var at = 0
                    let ranges = own.map { m -> Range<Int> in defer { at += m.wordIndices.count }; return at..<(at+m.wordIndices.count) }
                    let turn = Turn(id:result.count,speaker:row.speaker,items:own.flatMap(\.wordIndices).map(item),startMs:row.startMs,endMs:row.endMs,fragments:ranges,pools:own.map { spans($0.wordIndices.map(item)) },over:row.over,continuation:row.continuation,crosstalk:row.crosstalk)
                    rowByID[turn.id] = row; result.append(turn)
                }
            }
        }
        let childByFirstWord = Dictionary(uniqueKeysWithValues:rendered.runs.filter { $0.host != nil }.map { (rendered.blocks[$0.blocks[0]].wordIndices[0],$0.id) })
        for (id,row) in rowByID {
            var after = -1
            for member in row.members {
                if member.kind == "words" { after += member.wordIndices.count }
                else if let word = member.wordIndices.first, let run = childByFirstWord[word], let child = firstID[run] {
                    result[id].asides.append((after,child)); result[child].host = id
                }
            }
        }
        return result
    }
    /// The turns shown as paragraphs: every turn not shown inside another.
    public static func visibleTurns(_ turns: [Turn]) -> [Turn] { turns.filter { $0.host == nil } }
    public struct Prose: Sendable {
        public struct Seek: Sendable { public let range: Range<Int>; public let item: LibraryTranscriptItem; public let turnID: Int }
        public let text: String
        public let seeks: [Seek]
    }
    /// One copy/search/export projection; chips remain inline and every word keeps its seek anchor.
    public static func prose(_ turn: Turn, in turns: [Turn], names: [String:String] = [:], locale: Locale = .current, language: CassiniLanguage = .system) -> Prose {
        var text = "", seeks: [Prose.Seek] = []
        func append(_ item: LibraryTranscriptItem, turnID: Int) {
            let at = text.utf16.count
            text += item.text
            seeks.append(.init(range:at..<text.utf16.count,item:item,turnID:turnID))
        }
        for (i,item) in turn.items.enumerated() {
            if !text.isEmpty { text += " " }
            append(item,turnID:turn.id)
            for aside in turn.asides where aside.after == i && turns.indices.contains(aside.turn) {
                let child = turns[aside.turn]
                let marker = "\u{E000}"
                let template = LibraryLocalization.shared.text("meeting.turn.aside",["name":names[child.speaker] ?? child.speaker,"text":marker],language:language,locale:locale).components(separatedBy:marker)
                text += " (" + template[0]
                for (i,word) in child.items.enumerated() { if i > 0 { text += " " }; append(word,turnID:child.id) }
                text += template.dropFirst().joined(separator:marker) + ")"
            }
        }
        return .init(text:text,seeks:seeks)
    }
    public static func speakerList(_ names: [String]) -> String { TranscriptRendering.speakerList(names) }
    /// Meeting data for directly opened files, without an app-owned sidecar.
    public static func external(_ file: CassiniFile, url: URL) -> LibraryMeeting {
        let trusted = file.state == .ok
        let timed = file.transcripts.filter { $0.entry.format == "cassini.words.v1" }
        let emptyTimed = trusted && !timed.isEmpty && timed.allSatisfy { $0.load.transcript?.items.isEmpty == true }
        let body = trusted && !emptyTimed ? file.defaultTranscript?.load.transcript : nil
        let status: TranscriptStatus = emptyTimed || file.state == .plainAudio ? .none : (body != nil ? .done : .damaged)
        let words = (body?.items ?? []).map { LibraryTranscriptItem(speaker: $0.speaker, startMs: Int64($0.startMs), endMs: Int64($0.endMs), text: $0.text, lowConfidenceSpeaker:$0.lowConfidenceSpeaker ? true : nil) }
        var ids: [String] = []
        for word in words.enumerated().sorted(by:{ $0.element.startMs == $1.element.startMs ? $0.offset < $1.offset : $0.element.startMs < $1.element.startMs }).map(\.element) where !ids.contains(word.speaker) { ids.append(word.speaker) }
        let speakers = ids.enumerated().map { index, id in
            MeetingSpeaker(id: id, name: file.manifest?.speaker(id)?.label, provenance: nil, colourIndex: index)
        }
        var duration: Int64?
        if case .success(let digest)? = file.audioDigest { duration = Int64(digest.durationMs) }
        let title = file.manifest?.meeting.title ?? file.tags?["TITLE"] ?? url.deletingPathExtension().lastPathComponent
        // An unverifiable identifier must not become a fresh export identity.
        let id = trusted ? file.manifest.flatMap { UUID(uuidString:$0.meeting.id) } : nil
        var result = LibraryMeeting(id: id ?? UUID(),
            folder: url.deletingLastPathComponent().appendingPathComponent("External-" + url.lastPathComponent),
            state: .init(origin: .received, transcript: status, audioAvailable: duration != nil),
            title: title, start: file.meetingTime?.instant, durationMs: duration,
            speakers: speakers, quote: nil, notes: [], audioFiles: [url], issues: [])
        result.recordedTime = file.meetingTime
        result.sortingFallback = file.manifest.flatMap { MeetingTime.parseInstant($0.meeting.createdAtUtc) }
        result.metadataReadOnly = true; result.transcriptItems = words
        result.summaryMarkdown = trusted ? file.manifest?.summaryMarkdown : nil
        result.wordEndsBoundedByAudio = trusted && file.manifest?.wordEndsBoundedByAudio == true
        result.exportTitle = trusted || file.state == .plainAudio ? title : url.deletingPathExtension().lastPathComponent
        return result
    }
}
