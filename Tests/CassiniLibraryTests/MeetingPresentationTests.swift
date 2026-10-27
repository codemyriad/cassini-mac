// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import CassiniLibrary

struct MeetingPresentationTests {
    @Test func sharesUseLargestRemainderWithFirstSpeakingTies() {
        var meeting = LibraryMeeting(id: UUID(), folder: URL(fileURLWithPath: "/fixture"), state: .init(), title: nil,
            start: nil, durationMs: nil, speakers: ["a", "b", "c"].enumerated().map { .init(id: $0.element, provenance: .unnamed, colourIndex: $0.offset) }, quote: nil, notes: [], audioFiles: [], issues: [])
        meeting.transcriptItems = ["a", "b", "c"].map { .init(speaker: $0, startMs: 0, endMs: 1000, text: $0) }
        #expect(MeetingPresentation.shares(meeting) == ["a": 34, "b": 33, "c": 33])
        meeting.transcriptItems = [.init(speaker: "a", startMs: 0, endMs: 23000, text: "a"), .init(speaker: "b", startMs: 0, endMs: 19000, text: "b"), .init(speaker: "c", startMs: 0, endMs: 11000, text: "c")]
        #expect(MeetingPresentation.shares(meeting) == ["a": 43, "b": 36, "c": 21])
        meeting.transcriptItems = []
        #expect(MeetingPresentation.shares(meeting).values.allSatisfy { $0 == 0 })
    }
    @Test func turnsRetainExactSentenceAndWordBoundaries() {
        let items: [LibraryTranscriptItem] = [.init(speaker: "a", startMs: 0, endMs: 3000, text: "One sentence."), .init(speaker: "a", startMs: 4000, endMs: 4500, text: "One"), .init(speaker: "b", startMs: 4100, endMs: 4900, text: "yes")]
        let turns = MeetingPresentation.turns(items)
        #expect(turns.count == 2 && turns[0].items == Array(items.prefix(2)) && turns[1].startMs == 4100)
    }
}
