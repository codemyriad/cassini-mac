// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import CassiniKit

@Suite struct CaptureEndEventsTests {
    @Test func terminalEventKeepsTheRestoredSourceAndIgnoresLateChanges() throws {
        let raw = try JSONParser.parse(Data("""
        [{"atMs":0,"type":"selection","me":true,"others":true,"reason":"start"},
         {"atMs":1,"type":"othersSource","source":"system","reason":"lost"},
         {"atMs":2,"type":"othersSource","source":"browser","reason":"restored"},
         {"atMs":3,"type":"end","reason":"callEnded"},
         {"atMs":4,"type":"othersSource","source":"none","reason":"user"},
         {"atMs":5,"type":"end","reason":"user"}]
        """.utf8))
        let events = CaptureEvent.read(raw)
        #expect(events.count == 4 && events.last?.reason == "callEnded")
        let state = CaptureSourceState(events:events,atMs:10)
        #expect(state.source == "browser" && state.reason == "restored" && state.sinceMs == 2)
        #expect(state.me == true && state.others == true && !state.fallback)
        let before = CaptureSourceState(events:events,atMs:1)
        #expect(before.source == "system" && before.fallback)
    }
    @Test(arguments:CaptureEndReason.allCases) func terminalReasonsEncodeOnlyTheirOwnFields(_ reason: CaptureEndReason) throws {
        let event = CaptureEvent(atMs:10,type:"end",reason:reason.rawValue)
        let object = try JSONParser.parse(JSONEncoder().encode(event))
        #expect(Set(object.keys) == Set(["atMs","type","reason"]))
        #expect(CaptureEvent.read(.array([object])) == [event])
    }
    @Test func unknownEndReasonAndFalseRestorationDoNotInventProvenance() throws {
        #expect(!CaptureEvent(atMs:0,type:"end",reason:"futureReason").isKnownValid)
        #expect(!CaptureEvent(atMs:0,type:"othersSource",source:"system",reason:"restored").isKnownValid)
        #expect(!CaptureEvent(atMs:0,type:"othersSource",source:"none",reason:"restored").isKnownValid)
        let root = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let fixture = try JSONParser.parse(Data(contentsOf:root.appendingPathComponent("browser-protocol/conformance/session-events/call-return.session.json")))
        let events = CaptureEvent.read(fixture["events"])
        #expect(events.last?.type == "end" && events.last?.atMs == 5000 && events.last?.reason == "callEnded")
        #expect(CaptureSourceState(events:events,atMs:5000).source == "browser")
    }
    @Test func aStandaloneRestoredEventCannotInventAFallbackHistory() throws {
        let event = CaptureEvent(atMs:1,type:"othersSource",source:"browser",reason:"restored")
        let raw = try JSONParser.parse(JSONEncoder().encode([event]))
        #expect(CaptureEvent.read(raw).isEmpty)
        #expect(CaptureSourceState(events:[event],atMs:2).source == nil)
    }

}
