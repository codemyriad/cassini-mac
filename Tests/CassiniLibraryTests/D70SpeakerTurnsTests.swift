// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
import CryptoKit
@testable import CassiniLibrary

/// D70/D70.1: shared English synthetic boundaries and GNOME #241 edge cases.
struct D70SpeakerTurnsTests {
    private struct Expected: Decodable, Equatable {
        let index: Int
        let speaker: String
        let startMs: Int64
        let endMs: Int64
        let wordIndices: [Int]
    }
    private struct Vector: Decodable {
        struct Speaker: Decodable { let id: String; let turns: Int }
        let language: String
        let items: [LibraryTranscriptItem]
        let speakers: [Speaker]
        let expectedTurns: [Expected]
    }
    private func word(_ speaker: String, _ start: Int64, _ end: Int64, _ text: String) -> LibraryTranscriptItem {
        .init(speaker: speaker, startMs: start, endMs: end, text: text)
    }

    @Test func sharedEnglishSyntheticVectorMatchesEveryBoundaryAndWordIndex() throws {
        let url = try #require(Bundle.module.url(forResource: "turns", withExtension: "json", subdirectory: "Golden/listen-by-speaker"))
        let data = try Data(contentsOf: url)
        #expect(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() == "0c0d49a7f1d57f97b243d08c0558ab13506a39a93316a2e7506d228f21d75e29")
        let vector = try JSONDecoder().decode(Vector.self, from: data)
        let turns = SpeakerTurn.grouping(vector.items)
        #expect(turns.map { Expected(index: $0.index, speaker: $0.speaker, startMs: $0.startMs, endMs: $0.endMs, wordIndices: $0.wordIndices) } == vector.expectedTurns)
        #expect(Dictionary(grouping: turns, by: \.speaker).mapValues(\.count) == Dictionary(uniqueKeysWithValues: vector.speakers.map { ($0.id, $0.turns) }))
        #expect(turns.count == 378 && vector.speakers.count == 14)
        #expect(vector.speakers.filter { $0.turns == 1 }.count == 8)
        #expect(turns[0].endMs == 59100 && turns[0].words.count == 122)
        #expect(turns.map { $0.endMs - $0.startMs }.min() == 300)
        #expect(turns.flatMap(\.words) == vector.items)
        #expect(vector.language == "en")
    }

    @Test func mergesRejoinRunsAcrossLongPausesAndKeepStoredWords() {
        let words = [word("a", 0, 100, "We"), word("b", 100, 200, "agree."), word("a", 90000, 90100, "Next.")]
        #expect(SpeakerTurn.grouping(words).count == 3)
        let merged = SpeakerMerges.apply(words, SpeakerMerges.resolve([.init(from: "b", into: "a")], known: ["a", "b"]))
        let turns = SpeakerTurn.grouping(merged)
        #expect(turns.count == 1)
        #expect(turns.first?.endMs == 90100)
        #expect(turns.first?.wordIndices == [0, 1, 2])
        #expect(turns.first?.text == "We agree. Next.")
        #expect(words[1].speaker == "b")
    }

    @Test func overlappingAsideKeepsItsOwnTurnAndOriginalIndices() {
        let words = [word("a", 700, 1000, "Continue."), word("a", 0, 900, "Hello."), word("b", 300, 600, "Yes.")]
        let turns = SpeakerTurn.grouping(words)
        #expect(turns.map(\.speaker) == ["a", "b", "a"])
        #expect(turns.map(\.wordIndices) == [[1], [2], [0]])
        #expect(turns.map(\.startMs) == [0, 300, 700])
        #expect(turns.map(\.endMs) == [900, 600, 1000])
        for turn in turns { #expect(turn.words == turn.wordIndices.map { words[$0] }) }
        let chronological = words.enumerated().sorted { $0.element.startMs < $1.element.startMs }.map(\.element)
        let rows = MeetingPresentation.turns(chronological)
        #expect(rows.contains { $0.speaker == "b" && $0.host != nil }, "Mac renders this voice as an aside chip")
    }

    @Test func equalStartsKeepInputOrderAndEmptyIsEmpty() {
        let words = [word("b", 0, 100, "First."), word("a", 0, 100, "Second."), word("b", 100, 200, "Third.")]
        #expect(SpeakerTurn.grouping(words).map(\.speaker) == ["b", "a", "b"])
        #expect(SpeakerTurn.grouping([]).isEmpty)
    }

    @Test func overlappingWordsKeepLongestEndAndDisplayOnlyPunctuation() {
        let words = [word("a", 0, 1000, "He said \"hello"), word("a", 100, 200, "world\".")]
        let turns = SpeakerTurn.grouping(words)
        #expect(turns.count == 1)
        #expect(turns.first?.endMs == 1000)
        #expect(turns.first?.text == "He said “hello world”.")
        #expect(turns.first?.words == words)
    }

    @Test func listeningIgnoresCaptureGapSplitsInTranscriptRows() {
        var meeting = LibraryMeeting(id: UUID(), folder: URL(fileURLWithPath: "/tmp/d70-synthetic"), state: .init(transcript: .done), title: "Synthetic meeting", start: nil, durationMs: nil, speakers: [], quote: nil, notes: [], audioFiles: [], issues: [])
        meeting.transcriptItems = [word("a", 0, 100, "Before."), word("a", 60000, 60100, "After.")]
        let gaps: SpeakerGapRanges.Ranges = ["a": [16000..<32000]]
        #expect(LibraryTranscriptTurn.coalescing(meeting.transcriptItems, gaps: gaps).count == 2)
        #expect(meeting.speakerTurns.count == 1)
        #expect(meeting.speakerTurns.first?.text == "Before. After.")
    }
}
