// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// D24/UX16: meeting.json `speakerMerges` is an ordered history of `{from, into}` overlays.
/// Readers apply the entries in order and resolve chains (A→B then B→C shows A and B as C);
/// transcript bodies are never rewritten. An entry whose `from` or `into` is not a known speaker
/// id, or that would merge a speaker into itself or close a cycle, is ignored. A later entry for
/// the same `from` replaces the earlier one (GNOME `resolve_merges` parity). Mac only reads
/// merges for now; writing them (Merge into…, Undo merge) waits for M4 (D70 item 11).
public enum SpeakerMerges {
    public struct Entry: Equatable, Sendable {
        public let from: String
        public let into: String
        public init(from: String, into: String) { self.from = from; self.into = into }
    }
    /// Each merged-away id mapped to its final target, chains resolved. Ids that stay are absent.
    public static func resolve(_ entries: [Entry], known: Set<String>) -> [String: String] {
        var links: [String: String] = [:]
        func final(_ id: String) -> String {
            var current = id
            while let next = links[current] { current = next }
            return current
        }
        for entry in entries {
            guard known.contains(entry.from), known.contains(entry.into) else { continue }
            let target = final(entry.into)
            guard target != entry.from else { continue } // a self edge, or one that would close a cycle
            links[entry.from] = target
        }
        return Dictionary(uniqueKeysWithValues: links.keys.map { ($0, final($0)) })
    }
    /// The words with each speaker id replaced by its final target; order and timing unchanged.
    public static func apply(_ words: [LibraryTranscriptItem], _ merged: [String: String]) -> [LibraryTranscriptItem] {
        guard !merged.isEmpty else { return words }
        return words.map { word in
            guard let target = merged[word.speaker] else { return word }
            return .init(speaker: target, startMs: word.startMs, endMs: word.endMs, text: word.text, lowConfidenceSpeaker:word.lowConfidenceSpeaker)
        }
    }
    /// D63 #2 after merges: a target splits on its own gap ranges and on those of every speaker
    /// merged into it. Reads the unmerged ranges, so the order of the entries changes nothing.
    public static func gaps(_ ranges: SpeakerGapRanges.Ranges, _ merged: [String: String]) -> SpeakerGapRanges.Ranges {
        guard !merged.isEmpty else { return ranges }
        var result = ranges
        for (source, target) in merged.sorted(by: { $0.key < $1.key }) {
            guard let own = ranges[source], !own.isEmpty else { continue }
            result[target, default: []] += own
        }
        return result.mapValues { $0.sorted { ($0.lowerBound, $0.upperBound) < ($1.lowerBound, $1.upperBound) } }
    }
}
