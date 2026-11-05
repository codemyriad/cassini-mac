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
        /// The first word of the first fragment, and the latest word end.
        public internal(set) var startMs: Int64
        public internal(set) var endMs: Int64
        /// Displayed-item ranges of the consecutive runs rejoined into this turn.
        public internal(set) var fragments: [Range<Int>]
        /// Audible spans of each fragment's words (zero-length words excluded).
        var pools: [[Span]]
        /// M11 (GNOME transcript.py): short turns of other speakers shown inline, each after
        /// the displayed item `after`; `host` is set on a turn shown inside another one.
        public internal(set) var asides: [(after: Int, turn: Int)] = []
        public internal(set) var host: Int?
        /// Speakers whose words overlap this turn's words by at least 150 ms.
        public internal(set) var over: [String] = []
    }
    typealias Span = (start: Int64, end: Int64)
    /// D52 M11 (GNOME transcript.py build_turns, from gocassini): rejoin a speaker's
    /// interrupted run when competing speech overlaps it, so mutual overlap reads as
    /// whole interleaved turns instead of alternating fragments. Quotes stay paired
    /// within each consecutive run (D38.5). Markdown export keeps consecutive runs (S-5).
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
    public static func turns(_ items: [LibraryTranscriptItem], gaps: SpeakerGapRanges.Ranges = [:]) -> [Turn] {
        (try? turns(items,gaps:gaps,cancellable:false)) ?? []
    }
    /// The same, for a caller off the main actor: with `cancellable`, a cancelled task stops
    /// at the next step with CancellationError (#118 review: long transcripts prepare off the
    /// main actor, and a superseded preparation never finishes).
    /// D63 #2: with `gaps` (SpeakerGapRanges), consecutive words of one speaker split where one of
    /// that speaker's gap ranges lies between their midpoints, and the 400 ms rejoin never joins
    /// across one; pauses inside presence still join.
    public static func turns(_ items: [LibraryTranscriptItem], gaps: SpeakerGapRanges.Ranges = [:], cancellable: Bool) throws -> [Turn] {
        let check: () throws -> Void = cancellable ? { try Task.checkCancellation() } : {}
        var fragments: [[LibraryTranscriptItem]] = []
        for item in items where !item.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if let last = fragments.last?.last, last.speaker == item.speaker, !SpeakerGapRanges.splits(last,item,gaps) {
                fragments[fragments.count - 1].append(item)
            } else { fragments.append([item]) }
        }
        let displayed: [[LibraryTranscriptItem]] = fragments.map { fragment in
            zip(fragment,TranscriptText.quotes(fragment.map(\.text))).compactMap { item,text in
                let text = text.split(whereSeparator: \.isWhitespace).joined(separator:" ")
                return text.isEmpty ? nil : .init(speaker:item.speaker,startMs:item.startMs,endMs:item.endMs,text:text)
            }
        }
        func touches(_ left: [Span], _ right: [Span]) -> Bool {
            left.contains { a in right.contains { c in max(a.start,c.start) - min(a.end,c.end) <= touchToleranceMs } }
        }
        let pools = fragments.map(spans)
        var result: [Turn] = [], open: [String:(turn: Int,fragment: Int)] = [:]
        for (position,fragment) in fragments.enumerated() {
            try check()
            let speaker = fragment[0].speaker, end = fragment.map(\.endMs).max() ?? 0
            var joined = false
            if let previous = open[speaker], let first = pools[position].first, !pools[previous.fragment].isEmpty,
               abs(first.start - result[previous.turn].endMs) <= seamGapMs,
               let last = fragments[previous.fragment].last, !SpeakerGapRanges.splits(last,fragment[0],gaps) {
                let intervening = pools[(previous.fragment + 1)..<position].flatMap { $0 }
                if intervening.isEmpty || touches(intervening,pools[previous.fragment] + pools[position]) {
                    let at = result[previous.turn].items.count
                    result[previous.turn].items += displayed[position]
                    result[previous.turn].fragments.append(at..<result[previous.turn].items.count)
                    result[previous.turn].pools.append(pools[position])
                    result[previous.turn].endMs = max(result[previous.turn].endMs,end)
                    open[speaker] = (previous.turn,position); joined = true
                }
            }
            if !joined, !displayed[position].isEmpty {
                result.append(.init(id:result.count,speaker:speaker,items:displayed[position],startMs:fragment[0].startMs,endMs:end,
                                    fragments:[0..<displayed[position].count],pools:[pools[position]]))
                open[speaker] = (result.count - 1,position)
            } else if !joined { open[speaker] = nil }
        }
        try attachAsides(&result,check:check)
        try markOverlap(&result,check:check)
        return result
    }
    /// Turn indices by start (ties in turn order): both passes sweep time in this order.
    private static func byStart(_ turns: [Turn]) -> [Int] {
        turns.indices.sorted { turns[$0].startMs == turns[$1].startMs ? $0 < $1 : turns[$0].startMs < turns[$1].startMs }
    }
    /// GNOME `_attach_asides`: a turn of at most 2 s of speech by another speaker, starting
    /// within 500 ms after one fragment of a longer host turn and ending within 500 ms before
    /// the host's next fragment, is shown inside the host. Never an aside inside an aside.
    ///
    /// #118 review: a sweep in start order. Only a turn with a seam (two or more fragments) can
    /// host, and only while it is still open (it started before the aside and has not ended
    /// before it); its seams are found by binary search over its fragment starts.
    static func attachAsides(_ turns: inout [Turn], check: () throws -> Void = {}) rethrows {
        // Each eligible host's non-empty fragments, in order, with their first word's start.
        var seams: [Int:[(fragment: Int, start: Int64)]] = [:]
        for turn in turns {
            let starts: [(fragment: Int, start: Int64)] = turn.pools.enumerated().compactMap { entry in entry.element.first.map { (entry.offset,$0.start) } }
            if turn.pools.count > 1, !starts.isEmpty { seams[turn.id] = starts }
        }
        /// The number of fragment starts below `value` (or at or below it, when `inclusive`).
        func count(_ starts: [(fragment: Int, start: Int64)], below value: Int64, inclusive: Bool = false) -> Int {
            var low = 0, high = starts.count
            while low < high {
                let mid = (low + high) / 2
                if inclusive ? starts[mid].start <= value : starts[mid].start < value { low = mid + 1 } else { high = mid }
            }
            return low
        }
        var candidates: [(turn: Int, host: Int, after: Int)] = []
        var open: [Int] = [], pending = byStart(turns).filter { seams[turns[$0].id] != nil }[...]
        for index in byStart(turns) {
            try check()
            let turn = turns[index]
            // Hosts that started before this turn join; hosts over before it began leave for good.
            while let next = pending.first, turns[next].startMs < turn.startMs { open.append(next); pending = pending.dropFirst() }
            open.removeAll { turns[$0].endMs < turn.startMs }
            let spans = union(turn.pools)
            guard !spans.isEmpty, spans.reduce(Int64(0),{ $0 + $1.end - $1.start }) <= asideMaxMs else { continue }
            var best: (score: (Int64,Int64), host: Int, after: Int)?
            for hostIndex in open.sorted() {
                let host = turns[hostIndex]
                guard host.speaker != turn.speaker, turn.endMs <= host.endMs, let starts = seams[host.id] else { continue }
                let pools = host.pools
                let earlier = count(starts,below:turn.startMs)
                guard earlier > 0 else { continue }
                let before = starts[earlier - 1].fragment
                guard before + 1 < pools.count, let left = pools[before].last, let right = pools[before + 1].first else { continue }
                // More than one fragment starting inside the turn: not a single seam.
                if count(starts,below:turn.endMs,inclusive:true) - count(starts,below:turn.startMs,inclusive:true) > 1 { continue }
                if turn.startMs - left.end > sideGapMs || right.start - turn.endMs > sideGapMs { continue }
                let score = (left.end,host.endMs - host.startMs)
                if best == nil || score > best!.score { best = (score,host.id,host.fragments[before].upperBound - 1) }
            }
            if let best { candidates.append((turn.id,best.host,best.after)) }
        }
        candidates.sort { $0.turn < $1.turn }
        let asides = Set(candidates.map(\.turn))
        for candidate in candidates where !asides.contains(candidate.host) {
            turns[candidate.turn].host = candidate.host
            turns[candidate.host].asides.append((candidate.after,candidate.turn))
        }
    }
    /// GNOME `_mark_overlap`: actual word overlap of at least 150 ms, not paragraph containment.
    /// #118 review: a sweep in start order, comparing a turn only with turns still open.
    static func markOverlap(_ turns: inout [Turn], check: () throws -> Void = {}) rethrows {
        let pools = turns.map { union($0.pools) }
        var open: [Int] = []
        for j in byStart(turns) {
            try check()
            open.removeAll { turns[$0].endMs <= turns[j].startMs }
            for k in open.sorted() {
                let (i,l) = k < j ? (k,j) : (j,k)
                let left = turns[i], right = turns[l]
                guard left.speaker != right.speaker, max(left.startMs,right.startMs) < min(left.endMs,right.endMs) else { continue }
                var a = 0, b = 0, overlap: Int64 = 0
                while a < pools[i].count && b < pools[l].count {
                    let x = pools[i][a], y = pools[l][b]
                    overlap += max(0,min(x.end,y.end) - max(x.start,y.start))
                    if x.end < y.end { a += 1 } else { b += 1 }
                }
                guard overlap >= overlapMinMs else { continue }
                if !turns[i].over.contains(right.speaker) { turns[i].over.append(right.speaker) }
                if !turns[l].over.contains(left.speaker) { turns[l].over.append(left.speaker) }
            }
            open.append(j)
        }
    }
    /// The turns shown as paragraphs: every turn not shown inside another.
    public static func visibleTurns(_ turns: [Turn]) -> [Turn] { turns.filter { $0.host == nil } }
    /// Meeting data for directly opened files, without an app-owned sidecar.
    public static func external(_ file: CassiniFile, url: URL) -> LibraryMeeting {
        let trusted = file.state == .ok
        let timed = file.transcripts.filter { $0.entry.format == "cassini.words.v1" }
        let emptyTimed = trusted && !timed.isEmpty && timed.allSatisfy { $0.load.transcript?.items.isEmpty == true }
        let body = trusted && !emptyTimed ? file.defaultTranscript?.load.transcript : nil
        let status: TranscriptStatus = emptyTimed || file.state == .plainAudio ? .none : (body != nil ? .done : .damaged)
        let words = (body?.items ?? []).map { LibraryTranscriptItem(speaker: $0.speaker, startMs: Int64($0.startMs), endMs: Int64($0.endMs), text: $0.text) }
            .enumerated().sorted { $0.element.startMs == $1.element.startMs ? $0.offset < $1.offset : $0.element.startMs < $1.element.startMs }.map(\.element)
        var ids: [String] = []
        for word in words where !ids.contains(word.speaker) { ids.append(word.speaker) }
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
            title: title, start: file.manifest.flatMap { recordingDate($0.meeting.createdAtUtc) }, durationMs: duration,
            speakers: speakers, quote: nil, notes: [], audioFiles: [url], issues: [])
        result.metadataReadOnly = true; result.transcriptItems = words
        result.exportTitle = trusted || file.state == .plainAudio ? title : url.deletingPathExtension().lastPathComponent
        return result
    }
}
