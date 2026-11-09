// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import CassiniKit

/// D70 listening span: a maximal chronological run of one speaker after merges.
/// Separate from transcript paragraphs: pauses, capture gaps and layout limits do not
/// split it, and another speaker's overlapping aside is a turn of its own.
public struct SpeakerTurn: Equatable, Sendable, Identifiable {
    /// Zero-based position among all turns, matching the shared D70 vector.
    public let index: Int
    public var id: Int { index }
    public let speaker: String
    public let words: [LibraryTranscriptItem]
    /// Indices in the caller's input, retained across sorting for transcript highlighting.
    public let wordIndices: [Int]
    public let startMs: Int64
    public let endMs: Int64
    public var text: String {
        words.map(\.text).joined(separator:" ")
    }

    /// GNOME `speaker_turns()` parity. Callers apply speakerMerges before grouping.
    /// Equal starts keep input order; overlapping words retain the longest end.
    public static func grouping(_ items: [LibraryTranscriptItem]) -> [Self] {
        var turns: [Self] = [], run: [LibraryTranscriptItem] = [], indices: [Int] = []
        var end: Int64 = 0
        func append() {
            turns.append(.init(index: turns.count, speaker: run[0].speaker, words: run,
                               wordIndices: indices, startMs: run[0].startMs, endMs: end))
        }
        for (index, word) in items.enumerated().sorted(by: {
            $0.element.startMs == $1.element.startMs ? $0.offset < $1.offset : $0.element.startMs < $1.element.startMs
        }) {
            if let previous = run.last, previous.speaker != word.speaker {
                append()
                run = []; indices = []
            }
            end = run.isEmpty ? word.endMs : max(end, word.endMs)
            run.append(word); indices.append(index)
        }
        if !run.isEmpty { append() }
        return turns
    }
}
