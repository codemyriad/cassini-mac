// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import CassiniLibrary

struct TranscriptFindTests {
    private let locale = Locale(identifier: "en_US")
    @Test func matchesDisplayedTextWithoutLosingUTF16Offsets() throws {
        let text = "🎙 Budget café, then CAFE\u{301}."
        let paragraph = TranscriptFind.Paragraph(id: 7, text: text)
        let hits = try TranscriptFind.matches(in: [paragraph], query: "cafe", locale: locale)
        #expect(hits.map(\.paragraph) == [7, 7])
        #expect(hits.map { (text as NSString).substring(with: $0.range) } == ["café", "CAFE\u{301}"])
        #expect(hits.first?.range.location == 10)
    }
    @Test func literalPhraseAndRepeatedOccurrencesStayInReadingOrder() throws {
        let paragraphs: [TranscriptFind.Paragraph] = [
            .init(id: 40, text: "Budget review. Budget review."),
            .init(id: 3, text: "Review the budget."),
            .init(id: 11, text: "One budget review, then stop.")]
        let hits = try TranscriptFind.matches(in: paragraphs, query: "  budget review\n", locale: locale)
        #expect(hits.map(\.paragraph) == [40, 40, 11])
        #expect(hits.map(\.range.location) == [0, 15, 4])
        #expect(try TranscriptFind.matches(in: paragraphs, query: "review. Review", locale: locale).isEmpty)
        #expect(try TranscriptFind.matches(in: paragraphs, query: "budget.*", locale: locale).isEmpty)
    }
    @Test func asidesAreSearchableInTheirDisplayedHostWithoutDuplicatingTurns() throws {
        let text = "We agreed (Dario: send the budget) on Friday."
        let hits = try TranscriptFind.matches(in: [.init(id: 19, text: text)], query: "send the budget", locale: locale)
        #expect(hits.count == 1)
        #expect(hits.first?.paragraph == 19)
        #expect(hits.map { (text as NSString).substring(with: $0.range) } == ["send the budget"])
    }
    @Test func noMatchesAndEmptyQueriesDoNotInventASelection() throws {
        for query in ["", " \n\t", "absent"] {
            let hits = try TranscriptFind.matches(in: [.init(id: 0, text: "budget")], query: query, locale: locale)
            #expect(hits.isEmpty)
            #expect(TranscriptFind.adjacent(to: nil, direction: .next, in: hits) == nil)
            #expect(TranscriptFind.adjacent(to: nil, direction: .previous, in: hits) == nil)
        }
    }
    @Test func nextAndPreviousWrapAcrossParagraphsAndRecoverAStaleSelection() throws {
        let hits = try TranscriptFind.matches(in: [.init(id: 8, text: "yes yes"), .init(id: 2, text: "yes")], query: "yes", locale: locale)
        #expect(TranscriptFind.adjacent(to: nil, direction: .next, in: hits) == hits.first)
        #expect(TranscriptFind.adjacent(to: nil, direction: .previous, in: hits) == hits.last)
        #expect(TranscriptFind.adjacent(to: hits.last, direction: .next, in: hits) == hits.first)
        #expect(TranscriptFind.adjacent(to: hits.first, direction: .previous, in: hits) == hits.last)
        #expect(TranscriptFind.adjacent(to: hits[0], direction: .next, in: hits) == hits[1])
        let stale = TranscriptFind.Match(paragraph: 99, range: NSRange(location: 0, length: 3))
        #expect(TranscriptFind.adjacent(to: stale, direction: .next, in: hits) == hits.first)
    }
    @Test func sharedProjectionFindsAnAsideOnceInItsActualHost() throws {
        let words: [LibraryTranscriptItem] = [
            .init(speaker: "claire", startMs: 0, endMs: 400, text: "We"),
            .init(speaker: "claire", startMs: 400, endMs: 800, text: "agree."),
            .init(speaker: "guest", startMs: 750, endMs: 1100, text: "Yes."),
            .init(speaker: "claire", startMs: 1000, endMs: 1800, text: "Thanks.")]
        let turns = MeetingPresentation.turns(words)
        let child = try #require(turns.first { $0.speaker == "guest" })
        let host = try #require(child.host)
        let paragraphs = MeetingPresentation.visibleTurns(turns).map {
            TranscriptFind.Paragraph(id: $0.id, prose: MeetingPresentation.prose($0, in: turns, names: ["guest": "Dario"], locale: locale, language: .en))
        }
        let hits = try TranscriptFind.matches(in: paragraphs, query: "Yes.", locale: locale)
        #expect(hits.count == 1)
        #expect(hits.first?.paragraph == host)
        let paragraph = try #require(paragraphs.first { $0.id == host })
        #expect(hits.map { (paragraph.text as NSString).substring(with: $0.range) } == ["Yes."])
        #expect(try TranscriptFind.matches(in: paragraphs, query: "Dario", locale: locale).isEmpty)
        #expect(try TranscriptFind.matches(in: paragraphs, query: "Dario: Yes", locale: locale).isEmpty)
        #expect(try TranscriptFind.matches(in: paragraphs, query: "We agree.", locale: locale).count == 1)
    }
    @Test func cancellationStopsAQueryBeforePublishingMatches() async throws {
        let ready = AsyncStream<Void>.makeStream()
        let gate = AsyncStream<Void>.makeStream()
        defer { ready.continuation.finish(); gate.continuation.finish() }
        let locale = locale
        let task = Task {
            ready.continuation.yield(())
            for await _ in gate.stream { break }
            return try TranscriptFind.matches(in: [.init(id: 0, text: "budget")], query: "budget", locale: locale)
        }
        for await _ in ready.stream { break }
        task.cancel()
        gate.continuation.yield(())
        do {
            _ = try await task.value
            Issue.record("Cancelled query returned matches")
        } catch is CancellationError { }
    }

    @Test func aSpokenSpeakerNameStillMatchesWithoutMatchingItsSyntheticLabel() throws {
        let words: [LibraryTranscriptItem] = [
            .init(speaker: "host", startMs: 0, endMs: 800, text: "We agree."),
            .init(speaker: "guest", startMs: 750, endMs: 1100, text: "Dario café."),
            .init(speaker: "host", startMs: 1000, endMs: 1800, text: "Thanks.")]
        let turns = MeetingPresentation.turns(words)
        let paragraphs = MeetingPresentation.visibleTurns(turns).map {
            TranscriptFind.Paragraph(id: $0.id, prose: MeetingPresentation.prose($0, in: turns, names: ["guest": "Dario"], locale: locale, language: .en))
        }
        let hits = try TranscriptFind.matches(in: paragraphs, query: "Dario cafe", locale: locale)
        #expect(hits.count == 1)
        let paragraph = try #require(paragraphs.first { $0.id == hits.first?.paragraph })
        #expect(hits.map { (paragraph.text as NSString).substring(with: $0.range) } == ["Dario café"])
        #expect(try TranscriptFind.matches(in: paragraphs, query: "Dario", locale: locale).count == 1)
        #expect(try TranscriptFind.matches(in: paragraphs, query: "Thanks.)", locale: locale).isEmpty)
    }

}
