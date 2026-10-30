// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
import Foundation
@testable import CassiniBrowserControl

private final class ReconnectClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval = 100
    var now: TimeInterval { lock.withLock { value } }
    func advance(_ amount: TimeInterval) { lock.withLock { value += amount } }
}
final class MeetingReconnectTests: XCTestCase {
    private let browser = BrowserInstance(pid:123,startSeconds:42)
    private func send(_ json: [String:Any], _ state: inout BrowserControlRegistry, _ id: UUID) throws {
        try state.receive(JSONSerialization.data(withJSONObject:json),from:id)
    }
    private func connect(_ state: inout BrowserControlRegistry, instance: BrowserInstance? = nil, tabs: [Int] = [2]) throws -> UUID {
        let id = UUID()
        try state.connect(.init(id:id,role:.control,browser:"Chrome",browserInstance:instance ?? browser))
        try send(["type":"hello","version":1,"capabilities":["independent-sessions-v1"]],&state,id)
        try inventory(tabs,&state,id)
        try send(status(),&state,id)
        return id
    }
    private func inventory(_ tabs: [Int], _ state: inout BrowserControlRegistry, _ id: UUID, suffix: String = "call") throws {
        try send(["type":"meetings","meetings":tabs.map { ["tabId":$0,"title":"Call","url":"https://meet.example/\(suffix)/\($0)","sourceCount":1] }],&state,id)
    }
    private func status(tab: Int? = nil, capture: String = "capture") -> [String:Any] {
        ["type":"status","recording":tab != nil,"tabId":tab.map { $0 as Any } ?? NSNull(),"path":NSNull(),"message":"Ready",
         "sessions":tab.map { [["tabId":$0,"recording":true,"captureId":capture,"path":NSNull(),"message":"Recording"]] } ?? []]
    }
    private func state(_ clock: ReconnectClock) -> BrowserControlRegistry { .init(clock:{ clock.now },instanceAlive:{ _ in true }) }
    func testStableKeyRetainsMicChoiceButCommandsUseTheNewPhysicalConnection() throws {
        let clock = ReconnectClock(); var state = state(clock)
        let first = try connect(&state); let key = BrowserMeetingKey(peer:first,tabID:2)
        state.disconnect(first)
        XCTAssertEqual(state.snapshots.first?.meetings.first?.key,key)
        XCTAssertEqual(state.snapshots.first?.reconciled,false)
        clock.advance(2)
        let next = try connect(&state)
        XCTAssertEqual(state.snapshots.count,1)
        XCTAssertEqual(state.snapshots.first?.meetings.first?.key,key)
        let request = try XCTUnwrap(state.startAll(microphone:true,choices:[key:false]).first)
        XCTAssertEqual(request.key,key); XCTAssertEqual(request.connectionID,next)
        let json = try JSONSerialization.jsonObject(with:request.data) as! [String:Any]
        XCTAssertEqual(json["microphone"] as? Bool,false)
        try send(["type":"result","requestId":request.id,"ok":true,"status":status(tab:2)],&state,next)
        XCTAssertEqual(state.outcomes.last?.key,key); XCTAssertEqual(state.outcomes.last?.ok,true)
        XCTAssertEqual(state.snapshots.first?.captures.first?.key,key)
    }
    func testLateOldTabDoesNotRekeyANewTabsPendingCommand() throws {
        let clock = ReconnectClock(); var state = state(clock)
        let first = try connect(&state); state.disconnect(first)
        let next = try connect(&state,tabs:[3])
        let newKey = BrowserMeetingKey(peer:next,tabID:3)
        let request = try state.start(newKey,microphone:false)
        try inventory([2,3],&state,next)
        let keys = Dictionary(uniqueKeysWithValues:state.snapshots.filter(\.reconciled).flatMap(\.meetings).map { ($0.key.tabID,$0.key) })
        XCTAssertEqual(keys[2],.init(peer:first,tabID:2)); XCTAssertEqual(keys[3],newKey)
        try send(["type":"result","requestId":request.id,"ok":true,"status":status(tab:3)],&state,next)
        XCTAssertEqual(state.outcomes.last?.requestID,request.id); XCTAssertEqual(state.outcomes.last?.key,newKey)
        XCTAssertEqual(try state.stop(newKey)?.connectionID,next)
    }
    func testLostStartWaitsAndReconcilesExactlyOnceWithoutSendingAnotherStart() throws {
        let clock = ReconnectClock(); var state = state(clock)
        let first = try connect(&state); let request = try state.start(.init(peer:first,tabID:2),microphone:false)
        state.disconnect(first)
        XCTAssertTrue(state.outcomes.isEmpty)
        clock.advance(2)
        let next = try connect(&state)
        XCTAssertTrue(state.outcomes.isEmpty,"An empty first status need not be the final inventory")
        XCTAssertTrue(state.automaticStarts(microphone:false).isEmpty)
        XCTAssertThrowsError(try state.start(request.key,microphone:true))
        try send(status(tab:2),&state,next)
        XCTAssertEqual(state.outcomes.count,1); XCTAssertEqual(state.outcomes.first?.requestID,request.id)
        XCTAssertEqual(state.outcomes.first?.ok,true)
        try send(status(tab:2),&state,next)
        clock.advance(20); state.expireRememberedStops()
        XCTAssertEqual(state.outcomes.count,1)
    }
    func testLostStartFailsOnlyAtDeadlineAndNeverSucceedsForADifferentAddress() throws {
        let clock = ReconnectClock(); var state = state(clock)
        let first = try connect(&state); let request = try state.start(.init(peer:first,tabID:2),microphone:false)
        state.disconnect(first)
        clock.advance(2)
        let next = try connect(&state)
        try inventory([2],&state,next,suffix:"different")
        try send(status(tab:2),&state,next)
        XCTAssertTrue(state.outcomes.isEmpty)
        clock.advance(7.9); state.expireRememberedStops(); XCTAssertTrue(state.outcomes.isEmpty)
        clock.advance(0.1); state.expireRememberedStops()
        XCTAssertEqual(state.outcomes.last?.requestID,request.id); XCTAssertEqual(state.outcomes.last?.ok,false)
    }
    func testProfilesAndANewBrowserProcessNeverInheritOtherMeetingKeys() throws {
        let clock = ReconnectClock(); var state = state(clock)
        let first = try connect(&state,tabs:[2]); let profile = try connect(&state,tabs:[3])
        state.disconnect(first)
        let replacement = try connect(&state,tabs:[2,4])
        let keys = state.snapshots.filter(\.reconciled).flatMap(\.meetings).map(\.key)
        XCTAssertTrue(keys.contains(.init(peer:first,tabID:2)))
        XCTAssertTrue(keys.contains(.init(peer:profile,tabID:3)))
        XCTAssertTrue(keys.contains(.init(peer:replacement,tabID:4)))
        let new = try connect(&state,instance:.init(pid:123,startSeconds:43),tabs:[2])
        XCTAssertEqual(state.snapshots.first(where:{ $0.id == new })?.meetings.first?.key,.init(peer:new,tabID:2))
    }
    func testExpiredReleasedLinkCannotDonateKeysOrReviveAnOldStart() throws {
        let clock = ReconnectClock(); var state = state(clock)
        let first = try connect(&state); let request = try state.start(.init(peer:first,tabID:2),microphone:false)
        state.disconnect(first); clock.advance(11)
        let next = try connect(&state)
        XCTAssertEqual(state.outcomes.last?.requestID,request.id); XCTAssertEqual(state.outcomes.last?.ok,false)
        XCTAssertEqual(state.snapshots.first?.meetings.first?.key,.init(peer:next,tabID:2))
        try send(status(tab:2),&state,next)
        XCTAssertEqual(state.outcomes.count,1)
    }
    func testReplacementCanArriveBeforeTheOldDisconnectWithoutDuplicatingStart() throws {
        let clock = ReconnectClock(); var state = state(clock)
        let first = try connect(&state)
        let request = try state.start(.init(peer:first,tabID:2),microphone:false)
        let next = try connect(&state)
        XCTAssertTrue(state.automaticStarts(microphone:false).isEmpty)
        state.disconnect(first)
        XCTAssertTrue(state.outcomes.isEmpty)
        try send(status(tab:2),&state,next)
        XCTAssertEqual(state.outcomes.map(\.requestID),[request.id]); XCTAssertEqual(state.outcomes.last?.ok,true)
    }
    func testSimultaneousProfileExpiryDeliversEveryCompletionBeyondHistoryLimit() throws {
        let clock = ReconnectClock(); var state = state(clock)
        var requests = Set<String>()
        for offset in [0,100] {
            let peer = try connect(&state,tabs:Array((1+offset)...(100+offset)))
            requests.formUnion(state.startAll(microphone:false).map(\.id))
            state.disconnect(peer)
        }
        XCTAssertEqual(requests.count,200)
        clock.advance(10); state.expireRememberedStops()
        let delivered = state.takeOutcomes()
        XCTAssertEqual(Set(delivered.map(\.requestID)),requests)
        XCTAssertEqual(delivered.count,200); XCTAssertTrue(delivered.allSatisfy { !$0.ok })
        XCTAssertTrue(state.takeOutcomes().isEmpty)
    }

    func testStatusBeforeDiscoveryDoesNotBindANewCaptureToTheOldAliasesAddress() throws {
        for returningSuffix in ["call","different"] {
            let clock = ReconnectClock(); var state = state(clock)
            let first = try connect(&state); state.disconnect(first)
            let next = try connect(&state,tabs:[])
            try send(status(tab:2,capture:"new-capture"),&state,next)
            try inventory([2],&state,next,suffix:"different")
            state.disconnect(next); state.rememberUserStop(captureID:"new-capture")
            let returned = try connect(&state,tabs:[])
            try inventory([2],&state,returned,suffix:returningSuffix)
            XCTAssertEqual(state.automaticStarts(microphone:false).count,returningSuffix == "call" ? 1 : 0)
        }
    }

    func testLateSupersededInventoryCannotReplaceTheCurrentAliasesStopAddress() throws {
        let clock = ReconnectClock(); var state = state(clock)
        let old = try connect(&state)
        let next = try connect(&state)
        try inventory([2],&state,next,suffix:"new")
        try send(status(tab:2,capture:"current-capture"),&state,next)
        try inventory([2],&state,old)
        let key = try XCTUnwrap(state.snapshots.first?.meetings.first?.key)
        let stopped = try XCTUnwrap(state.stop(key,captureID:"current-capture"))
        XCTAssertEqual(stopped.connectionID,next)
    }

    func testBufferedOldStartSuccessPreventsADuplicateButFailureIsNotLearned() throws {
        for ok in [false,true] {
            let clock = ReconnectClock(); var state = state(clock)
            let first = try connect(&state)
            let request = try state.start(.init(peer:first,tabID:2),microphone:false)
            _ = try connect(&state)
            try send(["type":"result","requestId":request.id,"ok":ok,"status":ok ? status(tab:2) : status()],&state,first)
            XCTAssertEqual(state.automaticStarts(microphone:false).count,ok ? 0 : 1)
        }
    }

}
