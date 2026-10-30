// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
import Foundation
@testable import CassiniBrowserControl

private final class ReviewClock: @unchecked Sendable {
    private let lock = NSLock(); private var instant: TimeInterval = 100
    var now: TimeInterval { lock.withLock { instant } }
    func advance(_ seconds: TimeInterval) { lock.withLock { instant += seconds } }
}
final class StopReviewRegressionTests: XCTestCase {
    private let instance = BrowserInstance(pid:123,startSeconds:42)
    private func state(_ clock: ReviewClock = ReviewClock()) -> BrowserControlRegistry { .init(clock:{ clock.now },instanceAlive:{ _ in true }) }
    private func send(_ json: [String:Any], _ state: inout BrowserControlRegistry, _ peer: UUID) throws {
        try state.receive(JSONSerialization.data(withJSONObject:json),from:peer)
    }
    private func connect(_ state: inout BrowserControlRegistry) throws -> UUID {
        let id = UUID(); try state.connect(.init(id:id,role:.control,browser:"Chrome",browserInstance:instance))
        try send(["type":"hello","version":1,"capabilities":["independent-sessions-v1"]],&state,id); return id
    }
    private func meetings(_ state: inout BrowserControlRegistry, _ peer: UUID, _ tabs: [Int] = [2], url: String = "old") throws {
        try send(["type":"meetings","meetings":tabs.map { ["tabId":$0,"title":"Call","url":"https://meet.example/\(url)/\($0)","sourceCount":1] }],&state,peer)
    }
    private func status(_ tabs: [Int] = []) -> [String:Any] {
        ["type":"status","recording":!tabs.isEmpty,"tabId":tabs.first.map { $0 as Any } ?? NSNull(),"path":NSNull(),"message":"Status",
         "sessions":tabs.map { ["tabId":$0,"captureId":"capture-\($0)","recording":true,"path":NSNull(),"message":"Recording"] }]
    }
    private func ready(_ state: inout BrowserControlRegistry, _ tabs: [Int] = [2], url: String = "old") throws -> UUID {
        let id = try connect(&state); try meetings(&state,id,tabs,url:url); try send(status(),&state,id); return id
    }
    func testSlowFirstInventoryKeepsAnUnexpiredExactStopIncludingInitialEmptyLists() throws {
        for emptyFirst in [false,true] {
            let clock = ReviewClock(); var state = state(clock)
            let first = try ready(&state); _ = try state.stop(.init(peer:first,tabID:2)); state.disconnect(first)
            let next = try connect(&state)
            if emptyFirst { try meetings(&state,next,[]) }
            clock.advance(11)
            try meetings(&state,next); try send(status(),&state,next)
            XCTAssertTrue(state.automaticStarts(microphone:false).isEmpty,"First discovery at11s must not undo Stop")
        }
    }
    func testStopAllAfterNavigationUsesTheCapturesOriginalCallAndLeavesNewURLRecordable() throws {
        var state = state(); let first = try ready(&state)
        try send(status([2]),&state,first); try meetings(&state,first,url:"new")
        let stop = try XCTUnwrap(state.stopAll().first)
        try send(["type":"result","requestId":stop.id,"ok":true,"status":status()],&state,first)
        XCTAssertEqual(state.automaticStarts(microphone:false).map(\.key.tabID),[2],"Old Stop completion cannot suppress the navigated call")
        state.disconnect(first); _ = try ready(&state,url:"new")
        XCTAssertEqual(state.automaticStarts(microphone:false).map(\.key.tabID),[2])
    }
    func testGlobalStopRetainsAnUnretiredStatusCaptureBeforeAudioRegistrationAfterDisconnect() throws {
        var state = state(); let first = try ready(&state)
        try send(status([2]),&state,first); state.disconnect(first)
        XCTAssertTrue(state.stopAll().isEmpty)
        _ = try ready(&state)
        XCTAssertTrue(state.automaticStarts(microphone:false).isEmpty)
    }
    func testGlobalStopRetainsAnUnboundStartAcrossDisconnect() throws {
        var state = state(); let first = try ready(&state)
        _ = try state.start(.init(peer:first,tabID:2),microphone:false)
        state.setRetainedCaptureIDs(["capture-2"]); state.disconnect(first)
        _ = state.stopAll(); _ = try ready(&state)
        XCTAssertTrue(state.automaticStarts(microphone:false).isEmpty)
    }
    func testUnboundIndividualStopResolvesWhenTheCaptureIDIsReportedLater() throws {
        var state = state(); let first = try ready(&state)
        state.setRetainedCaptureIDs(["capture-2"]); state.disconnect(first)
        state.rememberUserStop(key:.init(peer:first,tabID:2),captureID:"capture-2")
        let next = try ready(&state); try send(status([2]),&state,next)
        let stop = try XCTUnwrap(state.drainStops().first)
        XCTAssertEqual(stop.action,.stop); XCTAssertEqual(stop.key.peer,next)
        state.disconnect(next); _ = try ready(&state)
        XCTAssertTrue(state.automaticStarts(microphone:false).isEmpty)
    }
    func testGlobalStopIncludesTheSupersededProfilesNotYetRediscoveredTab() throws {
        var state = state(); let old = try ready(&state,[2,3]); try send(status([2,3]),&state,old)
        let next = try ready(&state,[3]); _ = state.stopAll()
        try meetings(&state,next,[2,3]); try send(status(),&state,next)
        XCTAssertFalse(state.automaticStarts(microphone:false).contains { $0.key.tabID == 2 })
    }
    func testOlderInventoryCannotEraseAStopAfterANewerEmptyPeerReconciles() throws {
        var state = state(); let old = try ready(&state); try send(status([2]),&state,old)
        let next = try ready(&state,[])
        state.rememberUserStop(captureID:"capture-2")
        try meetings(&state,old,url:"stale-navigation")
        try meetings(&state,next); try send(status(),&state,next)
        XCTAssertTrue(state.automaticStarts(microphone:false).isEmpty)
    }
    func testAutomaticStartCannotOverrideOrForgetAnExplicitStop() throws {
        var state = state(); let peer = try ready(&state); let key = BrowserMeetingKey(peer:peer,tabID:2)
        let stopped = try XCTUnwrap(state.stop(key))
        try send(["type":"result","requestId":stopped.id,"ok":true,"status":status()],&state,peer)
        XCTAssertThrowsError(try state.start(key,microphone:false,automatic:true))
        state.disconnect(peer); _ = try ready(&state)
        XCTAssertTrue(state.automaticStarts(microphone:false).isEmpty)
    }
    func testRetiredCapturesAndFailedStartsAreNotRememberedByLaterStopAll() throws {
        for failedStart in [false,true] {
            var state = state(); let peer = try ready(&state)
            if failedStart {
                let started = try state.start(.init(peer:peer,tabID:2),microphone:false)
                try send(["type":"result","requestId":started.id,"ok":false],&state,peer)
            } else {
                try send(status([2]),&state,peer); try send(status(),&state,peer)
            }
            state.disconnect(peer); _ = state.stopAll(); _ = try ready(&state)
            XCTAssertEqual(state.automaticStarts(microphone:false).count,1)
        }
    }
    func testUnboundStopResolvesToOriginalStartURLAfterDisconnectedNavigation() throws {
        var state = state(); let peer = try ready(&state)
        _ = try state.start(.init(peer:peer,tabID:2),microphone:false)
        state.disconnect(peer); state.rememberUserStop(captureID:"capture-2")
        let next = try ready(&state,url:"new"); try send(status([2]),&state,next)
        state.disconnect(next); _ = try ready(&state,url:"new")
        XCTAssertEqual(state.automaticStarts(microphone:false).map(\.key.tabID),[2])
    }

    func testVerifiedAbsenceStillRetiresOldStopAfterItsWindow() throws {
        let clock = ReviewClock(); var state = state(clock)
        let peer = try ready(&state); let stopped = try XCTUnwrap(state.stop(.init(peer:peer,tabID:2)))
        try send(["type":"result","requestId":stopped.id,"ok":true,"status":status()],&state,peer)
        try meetings(&state,peer,[]); clock.advance(11)
        try meetings(&state,peer)
        XCTAssertEqual(state.automaticStarts(microphone:false).count,1)
    }

    func testTwoProfilesVerifiedAbsenceStillRetiresOldStopAfterItsWindow() throws {
        for otherEmpty in [false,true] {
            let clock = ReviewClock(); var state = state(clock)
            let first = try ready(&state)
            let stopped = try XCTUnwrap(state.stop(.init(peer:first,tabID:2)))
            try send(["type":"result","requestId":stopped.id,"ok":true,"status":status()],&state,first)
            let other = try ready(&state,[8])
            if otherEmpty { try meetings(&state,other,[]) }
            try meetings(&state,first,[]); clock.advance(11)
            try meetings(&state,first)
            XCTAssertTrue(state.automaticStarts(microphone:false).contains { $0.key == .init(peer:first,tabID:2) },
                          "An independent profile must not preserve an expired Stop, even when its own inventory is now empty")
        }
    }
    func testTwoProfilesNavigateAwayAndBackDoesNotPreserveOldStop() throws {
        var state = state(); let first = try ready(&state)
        let stopped = try XCTUnwrap(state.stop(.init(peer:first,tabID:2)))
        try send(["type":"result","requestId":stopped.id,"ok":true,"status":status()],&state,first)
        _ = try ready(&state,[8])
        try meetings(&state,first,url:"different")
        XCTAssertEqual(state.rememberedStopCount,0,"The owner can retire its own Stop on navigation")
        try meetings(&state,first)
        XCTAssertTrue(state.automaticStarts(microphone:false).contains { $0.key == .init(peer:first,tabID:2) })
    }
    func testReplacementIdentifiedByEarlierTabsStillProtectsAgainstOldNavigation() throws {
        var state = state(); let old = try ready(&state)
        let stopped = try XCTUnwrap(state.stop(.init(peer:old,tabID:2)))
        try send(["type":"result","requestId":stopped.id,"ok":true,"status":status()],&state,old)
        try meetings(&state,old,[])
        let replacement = try ready(&state)
        try meetings(&state,replacement,[])
        try meetings(&state,old,url:"late-navigation")
        try meetings(&state,replacement)
        XCTAssertFalse(state.automaticStarts(microphone:false).contains { $0.key.tabID == 2 },
                       "The old lineage cannot erase Stop while the replacement temporarily reports no meetings")
    }

    func testHistoricalInterruptedStatusWithoutAnOwnedCaptureIsNotAnActiveStopTarget() throws {
        var state = state(); let peer = try ready(&state)
        var interrupted = status()
        interrupted["interrupted"] = [["tabId":2,"captureId":"old-saved","recording":false,"path":"/old/saved","message":"Interrupted"]]
        try send(interrupted,&state,peer)
        _ = state.stopAll(); state.disconnect(peer); _ = try ready(&state)
        XCTAssertEqual(state.automaticStarts(microphone:false).count,1)
    }

}
