// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
import Foundation
import CassiniKit
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

    func testLateOverlapRestoresStopRetiredByTheOldConnectionsStaleInventory() throws {
        for absence in [false,true] {
            let clock = ReviewClock(); var state = state(clock)
            let old = try ready(&state)
            let stopped = try XCTUnwrap(state.stop(.init(peer:old,tabID:2)))
            try send(["type":"result","requestId":stopped.id,"ok":true,"status":status()],&state,old)
            let replacement = try ready(&state,[3])
            if absence {
                try meetings(&state,old,[]); clock.advance(11)
                try meetings(&state,old)
            } else { try meetings(&state,old,url:"stale-navigation") }
            try meetings(&state,replacement,[2,3])
            let starts = state.automaticStarts(microphone:false)
            XCTAssertFalse(starts.contains { $0.key.tabID == 2 },"Late overlap must undo retirement by the superseded connection")
            XCTAssertTrue(starts.contains { $0.key.tabID == 3 },"The unrelated unstopped call remains recordable")
        }
    }
    func testDisconnectedOwnerHistoryStillRestoresStopOnLateOverlap() throws {
        for absence in [false,true] {
            let clock = ReviewClock(); var state = state(clock)
            let old = try ready(&state)
            let stopped = try XCTUnwrap(state.stop(.init(peer:old,tabID:2)))
            try send(["type":"result","requestId":stopped.id,"ok":true,"status":status()],&state,old)
            let replacement = try ready(&state,[3])
            if absence {
                try meetings(&state,old,[]); clock.advance(11)
                try meetings(&state,old)
            } else { try meetings(&state,old,url:"stale-navigation") }
            state.disconnect(old)
            try meetings(&state,replacement,[2,3])
            let starts = state.automaticStarts(microphone:false)
            XCTAssertFalse(starts.contains { $0.key.tabID == 2 },"Disconnect cannot discard the proof needed to restore this Stop")
            XCTAssertTrue(starts.contains { $0.key.tabID == 3 },"The independent unstopped tab remains recordable")
        }
    }

    func testAuthoritativeNavigationCannotReviveItsStopOnALaterReconnect() throws {
        for independentProfile in [false,true] {
            var state = state(); let old = try ready(&state)
            let stop = try XCTUnwrap(state.stop(.init(peer:old,tabID:2)))
            try send(["type":"result","requestId":stop.id,"ok":true,"status":status()],&state,old)
            if independentProfile { _ = try ready(&state,[8]) }
            try meetings(&state,old,url:"legitimate-navigation")
            state.disconnect(old)
            let later = try ready(&state,[2],url:"old")
            XCTAssertTrue(state.automaticStarts(microphone:false).contains { $0.key == .init(peer:later,tabID:2) },
                          "A new connection after an authoritative navigation cannot revive the previous call's Stop")
        }
    }

    func testDisconnectedLineageHistoryExpiresAndCannotRestoreAnOldStop() throws {
        let clock = ReviewClock(); var state = state(clock)
        let old = try ready(&state)
        let stopped = try XCTUnwrap(state.stop(.init(peer:old,tabID:2)))
        try send(["type":"result","requestId":stopped.id,"ok":true,"status":status()],&state,old)
        let replacement = try ready(&state,[3])
        try meetings(&state,old,url:"stale-navigation")
        state.disconnect(old)
        XCTAssertEqual(state.disconnectedLineageCount,1)
        clock.advance(UserStoppedCalls.retention+1)
        try meetings(&state,replacement,[2,3])
        XCTAssertEqual(state.disconnectedLineageCount,0)
        XCTAssertTrue(state.automaticStarts(microphone:false).contains { $0.key.tabID == 2 })
    }
    func testDisconnectedHistoriesStayBoundedAndResolveOnlyOverlappingProfiles() throws {
        let clock = ReviewClock(); var state = state(clock)
        var lastReplacement: UUID?
        for index in 0..<(UserStoppedCalls.limit+1) {
            clock.advance(1) // Keep unrelated known-call cache evictions deterministic.
            let tab = 2+index*2, partial = tab+1
            let old = try ready(&state,[tab])
            let stopped = try XCTUnwrap(state.stop(.init(peer:old,tabID:tab)))
            try send(["type":"result","requestId":stopped.id,"ok":true,"status":status()],&state,old)
            let replacement = try ready(&state,[partial])
            try meetings(&state,old,[tab],url:"stale-navigation")
            state.disconnect(old)
            if index < UserStoppedCalls.limit { state.disconnect(replacement) }
            else { lastReplacement = replacement }
            XCTAssertLessThanOrEqual(state.disconnectedLineageCount,UserStoppedCalls.limit)
        }
        XCTAssertEqual(state.disconnectedLineageCount,UserStoppedCalls.limit)
        let independent = try ready(&state,[9000])
        XCTAssertTrue(state.automaticStarts(microphone:false).contains { $0.key == .init(peer:independent,tabID:9000) })
        XCTAssertEqual(state.disconnectedLineageCount,UserStoppedCalls.limit,"Disjoint tabs cannot resolve another profile's history")
        let returning = try XCTUnwrap(lastReplacement)
        let stoppedTab = 2+UserStoppedCalls.limit*2
        try meetings(&state,returning,[stoppedTab,stoppedTab+1])
        XCTAssertFalse(state.automaticStarts(microphone:false).contains { $0.key == .init(peer:returning,tabID:stoppedTab) })
        XCTAssertEqual(state.disconnectedLineageCount,UserStoppedCalls.limit-1,"Resolved tombstone releases its history")
        clock.advance(UserStoppedCalls.retention+1); state.disconnect(returning); state.disconnect(independent)
        state.expireRememberedStops()
        XCTAssertEqual(state.disconnectedLineageCount,0)
    }

    func testLateOverlapNeverRestoresAnExpiredRetirement() throws {
        let clock = ReviewClock(); var state = state(clock)
        let old = try ready(&state)
        let stopped = try XCTUnwrap(state.stop(.init(peer:old,tabID:2)))
        try send(["type":"result","requestId":stopped.id,"ok":true,"status":status()],&state,old)
        let replacement = try ready(&state,[3])
        try meetings(&state,old,url:"stale-navigation")
        clock.advance(UserStoppedCalls.retention+1)
        try meetings(&state,replacement,[2,3])
        XCTAssertTrue(state.automaticStarts(microphone:false).contains { $0.key.tabID == 2 })
    }

    func testAutomaticTerminalReasonsDoNotBecomeUserStopsAfterTheD33Rebase() throws {
        for reason: CaptureEndReason in [.callEnded,.tabClosed,.pageGone,.disk,.error] {
            for all in [false,true] {
                var state = state(); let old = try ready(&state)
                try send(status([2]),&state,old)
                if all { _ = state.stopAll(reason:reason) }
                else { _ = try state.stop(.init(peer:old,tabID:2),reason:reason) }
                XCTAssertEqual(state.rememberedStopCount,0,"An automatic terminal reason must not remember a user Stop")
                state.disconnect(old); _ = try ready(&state)
                XCTAssertTrue(state.automaticStarts(microphone:false).contains { $0.key.tabID == 2 })
            }
        }
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
