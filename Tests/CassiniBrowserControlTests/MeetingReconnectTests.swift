// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
import Foundation
import CassiniKit
@testable import CassiniBrowserControl

private final class ReconnectClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval = 100
    private var dead: Set<BrowserInstance> = []
    var now: TimeInterval { lock.withLock { value } }
    func advance(_ amount: TimeInterval) { lock.withLock { value += amount } }
    func exit(_ instance: BrowserInstance) { _ = lock.withLock { dead.insert(instance) } }
    func alive(_ instance: BrowserInstance) -> Bool { lock.withLock { !dead.contains(instance) } }
}
/// A service-worker restart replaces the control link of one browser instance.
/// UI keys and an unacknowledged Start survive it; nothing is resent.
final class MeetingReconnectTests: XCTestCase {
    private let browser = BrowserInstance(pid:123,startSeconds:42)
    private func send(_ json: [String:Any], _ state: inout BrowserControlRegistry, _ id: UUID) throws {
        try state.receive(JSONSerialization.data(withJSONObject:json),from:id)
    }
    private struct Row { var tab = 2, generation: String? = "call-A", url = "https://meet.example/call" }
    private func connect(_ state: inout BrowserControlRegistry, instance: BrowserInstance? = nil, multiStream: Bool = true, rows: [Row] = [Row()]) throws -> UUID {
        let id = UUID()
        try state.connect(.init(id:id,role:.control,browser:"Chrome",browserInstance:instance ?? browser))
        try send(["type":"hello","version":1,"capabilities":["independent-sessions-v1"] + (multiStream ? ["multi-stream-v1"] : [])],&state,id)
        try inventory(rows,&state,id)
        try send(status(),&state,id)
        return id
    }
    private func inventory(_ rows: [Row], _ state: inout BrowserControlRegistry, _ id: UUID) throws {
        try send(["type":"meetings","meetings":rows.map { row -> [String:Any] in
            var entry: [String:Any] = ["tabId":row.tab,"title":"Call","url":row.url,"sourceCount":1]
            if let generation = row.generation { entry["callGeneration"] = generation }
            return entry
        }],&state,id)
    }
    private func status(tab: Int? = nil, capture: String = "capture", generation: String? = nil) -> [String:Any] {
        var session: [String:Any] = ["tabId":tab ?? 0,"recording":true,"captureId":capture,"path":NSNull(),"message":"Recording"]
        if let generation { session["callGeneration"] = generation }
        return ["type":"status","recording":tab != nil,"tabId":tab.map { $0 as Any } ?? NSNull(),"path":NSNull(),"message":"Ready",
                "sessions":tab == nil ? [] : [session]]
    }
    private func state(_ clock: ReconnectClock) -> BrowserControlRegistry {
        .init(clock:{ clock.now },instanceAlive:{ clock.alive($0) })
    }
    private func json(_ request: BrowserControlRequest) throws -> [String:Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with:request.data) as? [String:Any])
    }
    private func keys(_ state: BrowserControlRegistry) -> [Int:BrowserMeetingKey] {
        Dictionary(state.snapshots.filter(\.reconciled).flatMap(\.meetings).map { ($0.key.tabID,$0.key) },uniquingKeysWith:{ a,_ in a })
    }

    func testLostStartAcknowledgementAcrossAWorkerRestartSettlesOnceWithoutResend() throws {
        let clock = ReconnectClock(); var state = state(clock)
        let first = try connect(&state); let key = BrowserMeetingKey(peer:first,tabID:2)
        let request = try XCTUnwrap(state.automaticStarts(microphone:false).first)
        XCTAssertEqual(request.key,key); XCTAssertEqual(request.connectionID,first)
        XCTAssertEqual(try json(request)["callGeneration"] as? String,"call-A")
        state.disconnect(first)
        XCTAssertTrue(state.takeOutcomes().isEmpty,"The Start may be recording; its result was lost, not failed")
        // Retry and the microphone choice are keyed by the visible meeting.
        XCTAssertEqual(state.snapshots.map(\.reconciled),[false]); XCTAssertEqual(state.snapshots.first?.meetings.first?.key,key)
        clock.advance(2)
        // The restarted worker keeps callGeneration; the address may change.
        let next = try connect(&state,rows:[Row(url:"https://meet.example/call?authuser=0")])
        XCTAssertEqual(state.snapshots.count,1); XCTAssertEqual(keys(state)[2],key)
        XCTAssertTrue(state.takeOutcomes().isEmpty,"An empty first status is not the final inventory")
        XCTAssertTrue(state.automaticStarts(microphone:false).isEmpty,"An uncertain Start is never resent")
        XCTAssertThrowsError(try state.start(key,microphone:true)) { XCTAssertEqual($0 as? BrowserControlStateError,.busy) }
        try send(status(tab:2,generation:"call-A"),&state,next)
        let settled = state.takeOutcomes()
        XCTAssertEqual(settled,[.init(requestID:request.id,key:key,action:.start,ok:true,error:nil)])
        XCTAssertEqual(state.snapshots.first?.captures.first?.key,key)
        try send(status(tab:2,generation:"call-A"),&state,next)
        clock.advance(20); state.expireRememberedStops()
        XCTAssertTrue(state.takeOutcomes().isEmpty,"Settled exactly once")
        XCTAssertTrue(state.automaticStarts(microphone:false).isEmpty)
        // The surviving key routes to the current physical link.
        let stop = try XCTUnwrap(state.stop(key,userInitiated:false))
        XCTAssertEqual(stop.key,key); XCTAssertEqual(stop.connectionID,next); XCTAssertEqual(try json(stop)["captureId"] as? String,"capture")
    }
    func testADifferentCallGenerationOnTheReturningTabIsANewCallWithAFreshKey() throws {
        for (meeting,capture) in [("call-B","call-B"),("call-A","call-B")] {
            let clock = ReconnectClock(); var state = state(clock)
            let first = try connect(&state); let key = BrowserMeetingKey(peer:first,tabID:2)
            let request = try state.start(key,microphone:false)
            state.disconnect(first); clock.advance(1)
            let next = try connect(&state,rows:[Row(generation:meeting)])
            XCTAssertEqual(keys(state)[2],meeting == "call-A" ? key : .init(peer:next,tabID:2))
            try send(status(tab:2,generation:capture),&state,next)
            XCTAssertTrue(state.takeOutcomes().isEmpty,"Never settle against another call")
            clock.advance(8.5); state.expireRememberedStops(); XCTAssertTrue(state.takeOutcomes().isEmpty)
            clock.advance(0.5); state.expireRememberedStops()
            XCTAssertEqual(state.takeOutcomes(),[.init(requestID:request.id,key:key,action:.start,ok:false,error:nil)])
            state.expireRememberedStops(); XCTAssertTrue(state.takeOutcomes().isEmpty)
        }
    }
    func testHeldStartFailsOnceAtItsDeadlineAndAnExpiredLinkDonatesNothing() throws {
        let clock = ReconnectClock(); var state = state(clock)
        let first = try connect(&state); let request = try state.start(.init(peer:first,tabID:2),microphone:false)
        state.disconnect(first)
        clock.advance(9.5); state.expireRememberedStops(); XCTAssertTrue(state.takeOutcomes().isEmpty)
        clock.advance(0.5)
        let next = try connect(&state)
        XCTAssertEqual(state.takeOutcomes().map(\.requestID),[request.id]); XCTAssertEqual(state.outcomes.last?.ok,false)
        XCTAssertEqual(state.releasedCount,0)
        XCTAssertEqual(keys(state)[2],.init(peer:next,tabID:2))
        try send(status(tab:2,generation:"call-A"),&state,next)
        XCTAssertTrue(state.takeOutcomes().isEmpty)
    }
    func testBrowserExitAndServiceShutdownSettleHeldStartsAsFailed() throws {
        let clock = ReconnectClock(); var state = state(clock)
        let first = try connect(&state); let request = try state.start(.init(peer:first,tabID:2),microphone:false)
        state.disconnect(first); XCTAssertTrue(state.takeOutcomes().isEmpty)
        clock.exit(browser); state.expireRememberedStops()
        XCTAssertEqual(state.takeOutcomes(),[.init(requestID:request.id,key:request.key,action:.start,ok:false,error:nil)])
        XCTAssertTrue(state.snapshots.isEmpty)
        let other = BrowserInstance(pid:124,startSeconds:42)
        let peer = try connect(&state,instance:other); let held = try state.start(.init(peer:peer,tabID:2),microphone:false)
        state.disconnect(peer); XCTAssertTrue(state.takeOutcomes().isEmpty)
        state.finishReconnects()
        XCTAssertEqual(state.takeOutcomes().map(\.requestID),[held.id]); XCTAssertEqual(state.outcomes.last?.ok,false)
        // A link whose browser is already known to have exited holds nothing.
        let gone = try connect(&state,instance:other); let failed = try state.start(.init(peer:gone,tabID:2),microphone:false)
        clock.exit(other); state.disconnect(gone)
        XCTAssertEqual(state.takeOutcomes().map(\.requestID),[failed.id])
    }
    func testLegacyPeersReassociateOnlyByTheExactAddress() throws {
        for (address,settles) in [("https://meet.example/call",true),("https://meet.example/call?authuser=0",false)] {
            let clock = ReconnectClock(); var state = state(clock)
            let first = try connect(&state,multiStream:false); let key = BrowserMeetingKey(peer:first,tabID:2)
            let request = try state.start(key,microphone:false)
            XCTAssertNil(try json(request)["callGeneration"])
            state.disconnect(first)
            // Without multi-stream-v1 a generation field is not call identity.
            let next = try connect(&state,multiStream:false,rows:[Row(generation:"call-A",url:address)])
            XCTAssertEqual(keys(state)[2],settles ? key : .init(peer:next,tabID:2))
            try send(status(tab:2),&state,next)
            XCTAssertEqual(state.takeOutcomes().map(\.ok),settles ? [true] : [])
            clock.advance(10); state.expireRememberedStops()
            XCTAssertEqual(state.takeOutcomes().map(\.ok),settles ? [] : [false])
            XCTAssertEqual(state.outcomes.map(\.requestID),[request.id])
        }
    }
    func testProfilesAndAnotherBrowserProcessNeverInheritKeysOrSettleStarts() throws {
        let clock = ReconnectClock(); var state = state(clock)
        let first = try connect(&state,rows:[Row(tab:2)]); let profile = try connect(&state,rows:[Row(tab:3)])
        let request = try state.start(.init(peer:first,tabID:2),microphone:false)
        state.disconnect(first)
        // Another process reusing tab 2 and even the same generation string.
        let process = BrowserInstance(pid:123,startSeconds:43)
        let stranger = try connect(&state,instance:process,rows:[Row(tab:2)])
        try send(status(tab:2,generation:"call-A"),&state,stranger)
        XCTAssertTrue(state.takeOutcomes().isEmpty)
        let replacement = try connect(&state,rows:[Row(tab:2),Row(tab:4)])
        let current = Dictionary(state.snapshots.filter { $0.reconciled && $0.browserInstance == browser }.flatMap(\.meetings).map { ($0.key.tabID,$0.key) },uniquingKeysWith:{ a,_ in a })
        XCTAssertEqual(current,[2:.init(peer:first,tabID:2),3:.init(peer:profile,tabID:3),4:.init(peer:replacement,tabID:4)])
        XCTAssertEqual(state.snapshots.first { $0.id == stranger }?.meetings.first?.key,.init(peer:stranger,tabID:2))
        // The other process's recording on tab 2 cannot settle this Start.
        try send(status(tab:2,generation:"call-A"),&state,replacement)
        XCTAssertEqual(state.takeOutcomes().map(\.requestID),[request.id])
        XCTAssertEqual(try state.stop(.init(peer:stranger,tabID:2),userInitiated:false)?.connectionID,stranger)
        XCTAssertEqual(try state.stop(.init(peer:first,tabID:2),userInitiated:false)?.connectionID,replacement)
    }
    func testLateOldTabDoesNotRekeyANewTabsPendingCommand() throws {
        let clock = ReconnectClock(); var state = state(clock)
        let first = try connect(&state,rows:[Row(tab:2),Row(tab:3,generation:"call-C")]); state.disconnect(first)
        // The restarted worker first reports tab 3 in a new call and Starts it.
        let next = try connect(&state,rows:[Row(tab:3,generation:"call-D")])
        let newKey = BrowserMeetingKey(peer:next,tabID:3)
        XCTAssertEqual(keys(state)[3],newKey)
        let request = try state.start(newKey,microphone:false)
        try inventory([Row(tab:2),Row(tab:3,generation:"call-C")],&state,next)
        XCTAssertEqual(keys(state),[2:.init(peer:first,tabID:2),3:newKey])
        try send(["type":"result","requestId":request.id,"ok":true,"status":status(tab:3,generation:"call-D")],&state,next)
        XCTAssertEqual(state.takeOutcomes(),[.init(requestID:request.id,key:newKey,action:.start,ok:true,error:nil)])
        XCTAssertEqual(try state.stop(newKey)?.connectionID,next)
    }
    func testReplacementReportingBeforeTheOldDisconnectSettlesWithoutADuplicate() throws {
        let clock = ReconnectClock(); var state = state(clock)
        let first = try connect(&state)
        let request = try state.start(.init(peer:first,tabID:2),microphone:false)
        let next = try connect(&state)
        XCTAssertTrue(state.automaticStarts(microphone:false).isEmpty)
        try send(status(tab:2,generation:"call-A"),&state,next)
        XCTAssertTrue(state.takeOutcomes().isEmpty,"The old link may still acknowledge it")
        state.disconnect(first)
        XCTAssertEqual(state.takeOutcomes().map(\.requestID),[request.id]); XCTAssertEqual(state.outcomes.last?.ok,true)
    }
    func testBufferedOldStartSuccessPreventsADuplicateButFailureIsNotLearned() throws {
        for ok in [false,true] {
            let clock = ReconnectClock(); var state = state(clock)
            let first = try connect(&state)
            let request = try state.start(.init(peer:first,tabID:2),microphone:false)
            _ = try connect(&state)
            try send(["type":"result","requestId":request.id,"ok":ok,"status":ok ? status(tab:2,generation:"call-A") : status()],&state,first)
            XCTAssertEqual(state.automaticStarts(microphone:false).count,ok ? 0 : 1)
        }
    }
    func testStableKeyKeepsTheMicrophoneChoiceAndRoutesToTheNewConnection() throws {
        let clock = ReconnectClock(); var state = state(clock)
        let first = try connect(&state); let key = BrowserMeetingKey(peer:first,tabID:2)
        state.disconnect(first); clock.advance(2)
        let next = try connect(&state)
        let request = try XCTUnwrap(state.startAll(microphone:true,choices:[key:false]).first)
        XCTAssertEqual(request.key,key); XCTAssertEqual(request.connectionID,next)
        XCTAssertEqual(try json(request)["microphone"] as? Bool,false)
        try send(["type":"result","requestId":request.id,"ok":true,"status":status(tab:2,generation:"call-A")],&state,next)
        XCTAssertEqual(state.takeOutcomes().map(\.key),[key])
        XCTAssertTrue(try XCTUnwrap(state.snapshots.first).owns(key))
    }
    func testRepeatedRestartsKeepOneKeyListedOnce() throws {
        let clock = ReconnectClock(); var state = state(clock)
        let first = try connect(&state); let key = BrowserMeetingKey(peer:first,tabID:2)
        state.disconnect(first); clock.advance(1)
        let second = try connect(&state); state.disconnect(second); clock.advance(1)
        XCTAssertEqual(state.snapshots.flatMap(\.meetings).map(\.key),[key])
        XCTAssertEqual(state.snapshots.map(\.id),[second])
        _ = try connect(&state)
        XCTAssertEqual(state.snapshots.flatMap(\.meetings).map(\.key),[key]); XCTAssertEqual(keys(state)[2],key)
    }
    func testSimultaneousExpiryDeliversEveryCompletionAndReleasedLinksStayBounded() throws {
        let clock = ReconnectClock(); var state = state(clock)
        var requests = Set<String>()
        for offset in [0,100] {
            let peer = try connect(&state,rows:(1...100).map { Row(tab:$0+offset,generation:"call-\($0+offset)") })
            requests.formUnion(state.startAll(microphone:false).map(\.id))
            state.disconnect(peer)
        }
        XCTAssertEqual(requests.count,200)
        clock.advance(10); state.expireRememberedStops()
        let delivered = state.takeOutcomes()
        XCTAssertEqual(Set(delivered.map(\.requestID)),requests); XCTAssertEqual(delivered.count,200)
        XCTAssertTrue(delivered.allSatisfy { !$0.ok }); XCTAssertTrue(state.takeOutcomes().isEmpty)
        for index in 0..<130 {
            let peer = try connect(&state,instance:.init(pid:200+Int32(index),startSeconds:42))
            _ = try state.start(.init(peer:peer,tabID:2),microphone:false); state.disconnect(peer)
            clock.advance(0.01)
        }
        XCTAssertEqual(state.releasedCount,128)
        XCTAssertEqual(state.takeOutcomes().count,2,"The two oldest held Starts fail when evicted")
    }
}
