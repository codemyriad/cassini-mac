// SPDX-License-Identifier: GPL-3.0-or-later
import Testing
@testable import CassiniLibrary

@Suite struct D70TranscriptListeningTests {
    @Test func asideHighlightUsesItsOwnWordsButScrollsToTheHost() throws {
        let words: [LibraryTranscriptItem] = [
            .init(speaker:"claire",startMs:0,endMs:400,text:"We"),
            .init(speaker:"claire",startMs:400,endMs:800,text:"agree."),
            .init(speaker:"guest",startMs:750,endMs:1100,text:"Yes."),
            .init(speaker:"claire",startMs:1000,endMs:1800,text:"Thanks.")]
        let rows = MeetingPresentation.turns(words), turns = SpeakerTurn.grouping(words)
        let aside = try #require(rows.first { $0.speaker == "guest" })
        let host = try #require(aside.host)
        let mapping = TranscriptListening(rows:rows,turns:turns)
        #expect(mapping.words(in:aside.id,listeningTo:1) == [0])
        #expect(mapping.words(in:host,listeningTo:1).isEmpty)
        #expect(mapping.host(forListening:1) == host)
        #expect(mapping.host(forReading:aside.id) == host)
        #expect(mapping.listeningIndex(forReading:aside.id,at:900) == 1)
        #expect(mapping.words(in:host,listeningTo:nil).isEmpty)
        // The host rejoins around the chip, while listening retains both Claire runs.
        #expect(mapping.words(in:host,listeningTo:0) == [0,1])
        #expect(mapping.words(in:host,listeningTo:2) == [2])
        #expect(mapping.listeningIndex(forReading:host,at:1300) == 2)
    }
    @Test func captureGapRowsAndQuotedTextDoNotChangeExactHighlightMembership() throws {
        let words = (0..<105).map { i in LibraryTranscriptItem(speaker:"ada",startMs:Int64(i)*500,endMs:Int64(i)*500+300,text:i==0 ? "\"Hello" : "word") }
        let rows = MeetingPresentation.turns(words,gaps:["ada":[400000..<403200]]), turns = SpeakerTurn.grouping(words)
        let mapping = TranscriptListening(rows:rows,turns:turns)
        #expect(turns.count == 1 && rows.count > 1)
        #expect(rows.reduce(0) { $0+mapping.words(in:$1.id,listeningTo:0).count } == 105)
        #expect(mapping.host(forListening:0) == rows.first?.id)
        #expect(mapping.listeningIndex(forReading:rows.last!.id,at:0) == 0)
    }
    @Test func duplicateTimestampsRemainAssignedToTheirOwnRun() {
        let words: [LibraryTranscriptItem] = [.init(speaker:"ada",startMs:0,endMs:500,text:"Yes."),
            .init(speaker:"sam",startMs:0,endMs:500,text:"Agreed."),.init(speaker:"ada",startMs:0,endMs:500,text:"Indeed.")]
        let rows = MeetingPresentation.turns(words), turns = SpeakerTurn.grouping(words)
        let mapping = TranscriptListening(rows:rows,turns:turns)
        #expect(rows.reduce(0) { $0+mapping.words(in:$1.id,listeningTo:0).count } == 1)
        #expect(rows.reduce(0) { $0+mapping.words(in:$1.id,listeningTo:2).count } == 1)
    }
    @Test func handScrollingSuppressesFollowForFourSecondsAndStepsResumeImmediately() {
        var follow = TranscriptFollow()
        #expect(follow.allowsFollow(at:0))
        follow.handScrolled(at:100)
        #expect(!follow.allowsFollow(at:103.999))
        #expect(follow.allowsFollow(at:104))
        follow.handScrolled(at:105); follow.handScrolled(at:106)
        #expect(!follow.allowsFollow(at:109))
        follow.stepped()
        #expect(follow.allowsFollow(at:107))
    }
}
