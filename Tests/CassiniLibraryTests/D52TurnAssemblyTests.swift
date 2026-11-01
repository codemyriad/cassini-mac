// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import CassiniLibrary

/// D52 M11: overlapping speech reads as whole interleaved turns (GNOME build_turns rejoin).
struct D52TurnAssemblyTests {
    private func item(_ speaker: String, _ start: Int64, _ end: Int64, _ text: String) -> LibraryTranscriptItem { .init(speaker:speaker,startMs:start,endMs:end,text:text) }
    private func sorted(_ items: [LibraryTranscriptItem]) -> [LibraryTranscriptItem] { items.sorted { $0.startMs < $1.startMs } }
    @Test func sixSecondsOfMutualOverlapGiveTwoTurns() {
        var items: [LibraryTranscriptItem] = []
        for k in Int64(0)..<12 { items.append(item("a",k*500,k*500+400,"a\(k)")); items.append(item("b",k*500+250,k*500+650,"b\(k)")) }
        let turns = MeetingPresentation.turns(sorted(items))
        #expect(turns.map(\.speaker) == ["a","b"])
        #expect(turns[0].items.map(\.text) == (0..<12).map { "a\($0)" }); #expect(turns[1].items.map(\.text) == (0..<12).map { "b\($0)" })
    }
    @Test func anOrdinaryExchangeWithPausesKeepsItsTurns() {
        let turns = MeetingPresentation.turns([item("a",0,1000,"Hello"),item("b",1050,1500,"Hi"),item("a",1600,2000,"So")])
        #expect(turns.map(\.speaker) == ["a","b","a"],"600 ms after the run is a new turn")
    }
    @Test func aRunSeparatedByNonTouchingSpeechIsNotRejoined() {
        // b speaks in a clean pause of a: they never touch, so a's second fragment is a new turn.
        let turns = MeetingPresentation.turns([item("a",0,1000,"one"),item("b",1100,1200,"yes"),item("a",1300,1800,"two")])
        #expect(turns.map(\.speaker) == ["a","b","a"])
    }
    @Test func quotesPairWithinEachConsecutiveRun() {
        let turns = MeetingPresentation.turns([item("a",0,500,"\"Hello"),item("a",500,900,"there\""),item("b",950,1200,"ok")])
        #expect(turns.count == 2); #expect(turns[0].items.map(\.text).joined(separator:" ").contains("“Hello"))
    }
}
