// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
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
        #expect(mapping.hosts(forListening:1) == [host])
        #expect(mapping.followHost(forReading:aside.id,listeningTo:1) == host)
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
    @Test func otherSpeakerInLeadInOverlapAndTailCannotOverrideTheListeningHost() throws {
        let words: [LibraryTranscriptItem] = [
            .init(speaker:"sam",startMs:0,endMs:2500,text:"Before."),
            .init(speaker:"claire",startMs:3000,endMs:4500,text:"This turn."),
            .init(speaker:"sam",startMs:4500,endMs:6000,text:"After.")]
        let rows = MeetingPresentation.turns(words,endsBoundedByAudio:true), turns = SpeakerTurn.grouping(words)
        let mapping = TranscriptListening(rows:rows,turns:turns)
        let target = try #require(rows.first { $0.speaker == "claire" })
        let lead = try #require(rows.first { $0.speaker == "sam" })
        let tail = try #require(rows.last { $0.speaker == "sam" })
        #expect(lead.startMs <= 1500 && lead.items.contains { $0.endMs > 1500 })
        #expect(mapping.hosts(forListening:1) == [target.id])
        #expect(mapping.followHost(forReading:lead.id,listeningTo:1) == nil)
        #expect(mapping.followHost(forReading:tail.id,listeningTo:1) == nil)
        #expect(mapping.followHost(forReading:target.id,listeningTo:1) == target.id)
        #expect(mapping.host(forListening:1) == target.id)
        #expect(mapping.followHost(forReading:lead.id,listeningTo:nil) == lead.id)
        #expect(mapping.followHost(forReading:nil,listeningTo:1) == nil)
        var overlapWords: [LibraryTranscriptItem] = [.init(speaker:"claire",startMs:0,endMs:10000,text:"The target.")]
        for i in 0..<20 {
            let start = Int64(3000) + Int64(i)*250
            overlapWords.append(.init(speaker:"sam",startMs:start,endMs:start+200,text:"Overlap."))
        }
        let overlapRows = MeetingPresentation.turns(overlapWords,endsBoundedByAudio:true)
        let overlap = TranscriptListening(rows:overlapRows,turns:SpeakerTurn.grouping(overlapWords))
        let otherRows = overlapRows.filter { !overlap.hosts(forListening:0).contains($0.host ?? $0.id) }
        #expect(!otherRows.isEmpty)
        for row in otherRows { #expect(overlap.followHost(forReading:row.id,listeningTo:0) == nil) }
    }
    @Test func followKeepsEveryGapSplitTargetParagraph() throws {
        let words = (0..<105).map { i in LibraryTranscriptItem(speaker:"claire",startMs:Int64(i)*500,endMs:Int64(i)*500+300,text:"Word.") }
        let rows = MeetingPresentation.turns(words,gaps:["claire":[400000..<403200]])
        let mapping = TranscriptListening(rows:rows,turns:SpeakerTurn.grouping(words))
        #expect(rows.count > 1 && mapping.hosts(forListening:0) == Set(rows.map(\.id)))
        for row in rows { #expect(mapping.followHost(forReading:row.id,listeningTo:0) == row.id) }
    }
    @Test func mergedOverlapExcludesSelfAndDeduplicatesCanonicalIdentities() {
        var meeting = LibraryMeeting(id:UUID(),folder:URL(fileURLWithPath:"/synthetic"),state:.init(),title:nil,start:nil,durationMs:nil,
            speakers:[],quote:nil,notes:[],audioFiles:[],issues:[])
        meeting.mergedInto = ["old":"target","same":"target","other-old":"other"]
        #expect(meeting.overlappingSpeakerIDs(["same","target"],excluding:"old").isEmpty)
        #expect(meeting.overlappingSpeakerIDs(["same","other-old","other","third","other-old"],excluding:"old") == ["other","third"])
        #expect(meeting.overlappingSpeakerIDs(["one","two"],excluding:"unrelated") == ["one","two"])
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
