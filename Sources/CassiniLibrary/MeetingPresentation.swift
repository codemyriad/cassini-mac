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
        public var startMs: Int64 { items.first?.startMs ?? 0 }
    }
    /// D52 M11 (GNOME transcript.py build_turns, from gocassini): rejoin a speaker's
    /// interrupted run when competing speech overlaps it, so mutual overlap reads as
    /// whole interleaved turns instead of alternating fragments. Quotes stay paired
    /// within each consecutive run (D38.5). Markdown export keeps consecutive runs (S-5).
    public static let seamGapMs: Int64 = 400
    public static let touchToleranceMs: Int64 = 20
    public static func turns(_ items: [LibraryTranscriptItem]) -> [Turn] {
        var fragments: [[LibraryTranscriptItem]] = []
        for item in items where !item.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if fragments.last?.first?.speaker == item.speaker { fragments[fragments.count - 1].append(item) } else { fragments.append([item]) }
        }
        let displayed: [[LibraryTranscriptItem]] = fragments.map { fragment in
            zip(fragment,TranscriptText.quotes(fragment.map(\.text))).compactMap { item,text in
                let text = text.split(whereSeparator: \.isWhitespace).joined(separator:" ")
                return text.isEmpty ? nil : .init(speaker:item.speaker,startMs:item.startMs,endMs:item.endMs,text:text)
            }
        }
        /// Union of audible word intervals, excluding zero durations.
        func spans(_ words: [LibraryTranscriptItem]) -> [(Int64,Int64)] {
            var out: [(Int64,Int64)] = []
            for w in words.sorted(by:{ $0.startMs < $1.startMs }) where w.endMs > w.startMs {
                if let last = out.last, w.startMs <= last.1 { out[out.count-1].1 = max(last.1,w.endMs) } else { out.append((w.startMs,w.endMs)) }
            }
            return out
        }
        func touches(_ left: [(Int64,Int64)], _ right: [(Int64,Int64)]) -> Bool {
            left.contains { a in right.contains { c in max(a.0,c.0) - min(a.1,c.1) <= touchToleranceMs } }
        }
        let pools = fragments.map(spans)
        var result: [Turn] = [], ends: [Int64] = [], open: [String:(turn: Int,fragment: Int)] = [:]
        for (position,fragment) in fragments.enumerated() {
            let speaker = fragment[0].speaker
            var joined = false
            if let previous = open[speaker], let first = pools[position].first, !pools[previous.fragment].isEmpty,
               abs(first.0 - ends[previous.turn]) <= seamGapMs {
                let intervening = pools[(previous.fragment + 1)..<position].flatMap { $0 }
                if intervening.isEmpty || touches(intervening,pools[previous.fragment] + pools[position]) {
                    result[previous.turn].items += displayed[position]
                    ends[previous.turn] = max(ends[previous.turn],fragment.map(\.endMs).max() ?? 0)
                    open[speaker] = (previous.turn,position); joined = true
                }
            }
            if !joined, !displayed[position].isEmpty {
                result.append(.init(id:result.count,speaker:speaker,items:displayed[position]))
                ends.append(fragment.map(\.endMs).max() ?? 0)
                open[speaker] = (result.count - 1,position)
            } else if !joined { open[speaker] = nil }
        }
        return result
    }
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
