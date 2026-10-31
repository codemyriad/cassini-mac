// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import CassiniKit

/// R12: sum real item durations; distribute remaining percentage points by
/// largest remainder, with first-speaking order breaking ties.
public enum MeetingPresentation {
    public static func shares(_ meeting: LibraryMeeting) -> [String: Int] {
        let durations = Dictionary(grouping: meeting.transcriptItems.filter { !$0.echo }, by: \.speaker)
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
    public static func turns(_ items: [LibraryTranscriptItem]) -> [Turn] {
        var result: [Turn] = []
        for item in items where !item.echo && !item.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if result.last?.speaker == item.speaker { result[result.count - 1].items.append(item) }
            else { result.append(.init(id: result.count, speaker: item.speaker, items: [item])) }
        }
        return result.compactMap { turn in
            let pieces = TranscriptText.quotes(turn.items.map(\.text))
            let items = zip(turn.items,pieces).compactMap { item,text -> LibraryTranscriptItem? in
                let text = text.split(whereSeparator: \.isWhitespace).joined(separator:" ")
                guard !text.isEmpty else { return nil }
                return .init(speaker:item.speaker,startMs:item.startMs,endMs:item.endMs,text:text)
            }
            return items.isEmpty ? nil : Turn(id:turn.id,speaker:turn.speaker,items:items)
        }
    }
    /// Meeting data for directly opened files, without an app-owned sidecar.
    public static func external(_ file: CassiniFile, url: URL) -> LibraryMeeting {
        let trusted = file.state == .ok
        let timed = file.transcripts.filter { $0.entry.format == "cassini.words.v1" }
        let emptyTimed = trusted && !timed.isEmpty && timed.allSatisfy { $0.load.transcript?.items.isEmpty == true }
        let body = trusted && !emptyTimed ? file.defaultTranscript?.load.transcript : nil
        let status: TranscriptStatus = emptyTimed || file.state == .plainAudio ? .none : (body != nil ? .done : .damaged)
        let words = (body?.items ?? []).map { LibraryTranscriptItem(speaker: $0.speaker, startMs: Int64($0.startMs), endMs: Int64($0.endMs), text: $0.text, echo: $0.echo) }
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
