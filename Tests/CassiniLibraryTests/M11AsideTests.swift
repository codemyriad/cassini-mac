// SPDX-License-Identifier: GPL-3.0-or-later
import Testing
@testable import CassiniLibrary

/// D55 M11: GNOME transcript.py `_attach_asides` and `_mark_overlap`, on GNOME's own
/// tests (cassini-gnome tests/test_transcript.py).
struct M11AsideTests {
    private func w(_ speaker: String, _ start: Int64, _ end: Int64, _ text: String) -> LibraryTranscriptItem {
        .init(speaker:speaker,startMs:start,endMs:end,text:text)
    }
    private var words: [LibraryTranscriptItem] {
        [w("a",0,400,"So"),w("a",400,800,"I"),w("a",800,1200,"think"),w("a",1200,1600,"we"),w("a",1600,2000,"ship."),
         w("b",1900,2200,"Yeah."),w("a",2100,2500,"Then"),w("c",2600,3000,"Agreed,"),w("c",3000,3400,"totally.")]
    }
    private func text(_ turn: MeetingPresentation.Turn) -> String { turn.items.map(\.text).joined(separator:" ") }

    @Test func turnsKeepFileOrderAndAShortOverlappingTurnBecomesAnAside() {
        let turns = MeetingPresentation.turns(words)
        #expect(turns.map(\.speaker) == ["a","b","c"])
        #expect(text(turns[0]) == "So I think we ship. Then" && turns[2].endMs == 3400)
        #expect(turns[1].host == 0)
        #expect(turns[0].asides.map(\.after) == [4] && turns[0].asides.map(\.turn) == [1],"at the fragment seam, after “ship.”")
        #expect(turns[2].host == nil)
        #expect(MeetingPresentation.visibleTurns(turns).map(\.id) == [0,2])
    }
    @Test func aRapidCleanExchangeStaysSeparate() {
        let turns = MeetingPresentation.turns([w("a",0,1000,"Question?"),w("b",1050,1150,"Yes."),w("a",1200,2000,"Good.")])
        #expect(MeetingPresentation.visibleTurns(turns).map(text) == ["Question?","Yes.","Good."])
    }
    @Test func aLongPauseAndMassiveSelfOverlapDoNotRejoin() {
        for start: Int64 in [3000,500] {
            let turns = MeetingPresentation.turns([w("a",0,2000,"First"),w("b",1900,2200,"Right"),w("a",start,4000,"Second")])
            #expect(MeetingPresentation.visibleTurns(turns).count == 3,"\(start)")
        }
    }
    @Test func sustainedDoubleTalkIsNotScatteredIntoChips() {
        var list: [LibraryTranscriptItem] = []
        for i in 0..<12 { let i = Int64(i); list += [w("a",i*300,(i+1)*300,"a\(i)"),w("b",i*300+20,(i+1)*300+20,"b\(i)")] }
        let turns = MeetingPresentation.turns(list)
        #expect(turns.count == 2 && turns.allSatisfy { $0.host == nil })
        #expect(turns.reduce(0) { $0 + $1.items.count } == list.count)
    }
    @Test func wordCountDoesNotDisqualifyAShortBackchannel() {
        var list = [w("a",0,1000,"Before")]
        list += ["Yes","I","think","so"].enumerated().map { i,t in w("b",900 + Int64(i)*100,1000 + Int64(i)*100,t) }
        list += [w("a",1100,3000,"after")]
        let turns = MeetingPresentation.turns(list)
        #expect(turns[1].host == 0 && turns[0].asides.first?.after == 0)
    }
    @Test func anUnsplitHostDoesNotSwallowAnotherTurn() {
        let turns = MeetingPresentation.turns([w("a",0,4000,"Speech"),w("b",1500,1800,"Right")])
        #expect(MeetingPresentation.visibleTurns(turns).count == 2)
    }
    @Test func shortFragmentsWeavingThroughAHostAreCompetingSpeech() {
        var list: [LibraryTranscriptItem] = []
        for i in 0..<5 { let i = Int64(i); list += [w("a",i*200,(i+1)*200,"A"),w("b",i*200+20,(i+1)*200+20,"B")] }
        #expect(MeetingPresentation.visibleTurns(MeetingPresentation.turns(list)).count == 2)
    }
    @Test func theOverlapMarkUsesWordIntersectionsNotParagraphExtent() {
        let apart = MeetingPresentation.turns([w("a",0,500,"One"),w("a",3000,3500,"two"),w("b",1000,2000,"Reply")])
        #expect(apart.allSatisfy { $0.over.isEmpty })
        let over = MeetingPresentation.turns([w("a",0,2000,"One"),w("b",1500,2500,"Two")])
        #expect(over[0].over == ["b"] && over[1].over == ["a"])
    }
}
