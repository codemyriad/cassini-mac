// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
import Foundation
import Darwin
@testable import CassiniBrowserControl

private final class StopClock: @unchecked Sendable {
    private let lock = NSLock()
    private var instant: TimeInterval = 1000
    var now: TimeInterval { lock.withLock { instant } }
    func advance(_ seconds: TimeInterval) { lock.withLock { instant += seconds } }
}
final class UserStoppedCallTests: XCTestCase {
    private let instance = BrowserInstance(pid:123,startSeconds:42)
    private func send(_ object: [String:Any], _ state: inout BrowserControlRegistry, _ peer: UUID) throws {
        try state.receive(JSONSerialization.data(withJSONObject:object),from:peer)
    }
    private func meetings(_ entries: [(Int,String)], _ state: inout BrowserControlRegistry, _ peer: UUID) throws {
        try send(["type":"meetings","meetings":entries.map { ["tabId":$0.0,"title":"Call","url":$0.1,"sourceCount":1] }],&state,peer)
    }
    private func status(_ capture: String? = nil, tab: Int = 2) -> [String:Any] {
        ["type":"status","recording":capture != nil,"tabId":capture == nil ? NSNull() : tab,"path":NSNull(),"message":"Ready",
         "sessions":capture.map { [["recording":true,"tabId":tab,"captureId":$0,"path":NSNull(),"message":"Recording"]] } ?? []]
    }
    private func ready(_ state: inout BrowserControlRegistry, peer: UUID = UUID(), instance: BrowserInstance? = nil,
                       entries: [(Int,String)] = [(2,"https://meet.example/old")]) throws -> UUID {
        try state.connect(.init(id:peer,role:.control,browser:"Chrome",browserInstance:instance ?? self.instance))
        try send(["type":"hello","version":1,"capabilities":["independent-sessions-v1"]],&state,peer)
        try meetings(entries,&state,peer); try send(status(),&state,peer)
        return peer
    }
    private func state(_ clock: StopClock = StopClock()) -> BrowserControlRegistry {
        .init(clock:{ clock.now },instanceAlive:{ _ in true })
    }
    func testUserStopSurvivesReconnectButAnotherProfileAndBrowserInstanceCanStart() throws {
        var state = state(); let first = try ready(&state)
        _ = try state.stop(.init(peer:first,tabID:2)); state.disconnect(first)
        _ = try ready(&state)
        _ = try ready(&state,entries:[(3,"https://meet.example/old")])
        let other = try ready(&state,instance:.init(pid:123,startSeconds:43))
        XCTAssertEqual(state.automaticStarts(microphone:false).map(\.key.tabID).sorted(),[2,3])
        XCTAssertTrue(state.snapshots.first(where:{ $0.id == other }) != nil)
    }
    func testExpiredStopIsNotRevivedByTheReturningInventory() throws {
        let clock = StopClock(); var state = state(clock); let first = try ready(&state)
        _ = try state.stop(.init(peer:first,tabID:2)); state.disconnect(first)
        clock.advance(601)
        _ = try ready(&state)
        XCTAssertEqual(state.rememberedStopCount,0)
        XCTAssertEqual(state.automaticStarts(microphone:false).count,1)
    }
    func testDirectAddressChangeClearsSuppressionWithoutAnEmptyInventory() throws {
        var state = state(); let peer = try ready(&state)
        let stop = try XCTUnwrap(state.stop(.init(peer:peer,tabID:2)))
        // Complete the in-flight Stop before navigating to a new call.
        try send(["type":"result","requestId":stop.id,"ok":true,"status":status()],&state,peer)
        try meetings([(2,"https://meet.example/new")],&state,peer)
        XCTAssertEqual(state.automaticStarts(microphone:false).count,1)
        state.disconnect(peer); _ = try ready(&state,entries:[(2,"https://meet.example/new")])
        XCTAssertEqual(state.rememberedStopCount,0)
        XCTAssertEqual(state.automaticStarts(microphone:false).count,1)
    }
    func testLateWorkerReportsAndFreshDisconnectedStopUseTheStopTime() throws {
        let clock = StopClock(); var state = state(clock); let peer = try ready(&state)
        try send(status("original"),&state,peer)
        state.disconnect(peer)
        clock.advance(40)
        let replacement = try ready(&state,entries:[])
        clock.advance(40)
        state.rememberUserStop(captureID:"original")
        try meetings([(3,"https://meet.example/other")],&state,replacement)
        clock.advance(1)
        try meetings([(2,"https://meet.example/old"),(3,"https://meet.example/other")],&state,replacement)
        XCTAssertEqual(state.automaticStarts(microphone:false).map(\.key.tabID),[3])
    }
    func testNavigationWhileOldStopIsPendingCanStartAfterItsAcknowledgement() throws {
        var state = state(); let peer = try ready(&state)
        let stopped = try XCTUnwrap(state.stop(.init(peer:peer,tabID:2)))
        try meetings([(2,"https://meet.example/new")],&state,peer)
        XCTAssertTrue(state.drainStops().isEmpty)
        try send(["type":"result","requestId":stopped.id,"ok":true,"status":status()],&state,peer)
        XCTAssertEqual(state.automaticStarts(microphone:false).count,1)
    }
    func testLiveInventoryProtectsLongCallsButDeadBrowserAndAbsentCallsExpire() {
        var memory = UserStoppedCalls()
        let call = BrowserCallIdentity(instance:instance,tabID:2,url:"https://meet.example/old")
        memory.remember(call,now:0)
        memory.expire(now:700,priorLive:[call],alive:{ _ in true })
        XCTAssertTrue(memory.contains(call))
        memory.expire(now:701,priorLive:[call],alive:{ _ in false })
        XCTAssertEqual(memory.count,0)
    }
    func testOlderConnectionAndDisconnectedOldCaptureCannotEraseANewerCallStop() throws {
        var state = state(); let old = try ready(&state)
        try send(status("old-capture"),&state,old)
        let newer = try ready(&state,entries:[(2,"https://meet.example/new")])
        XCTAssertEqual(state.snapshots.count,1,"A draining superseded connection is not a second meeting profile")
        _ = try state.stop(.init(peer:newer,tabID:2))
        // A draining old host can still report its old page. Neither that
        // inventory nor a late Stop of its capture may erase the new Stop.
        try meetings([(2,"https://meet.example/old")],&state,old)
        state.rememberUserStop(captureID:"old-capture")
        state.disconnect(newer)
        _ = try ready(&state,entries:[(2,"https://meet.example/new")])
        XCTAssertTrue(state.automaticStarts(microphone:false).isEmpty)
    }
    func testDrainingOldConnectionCannotRegainAuthorityAfterReplacementDisconnects() throws {
        var state = state(); _ = try ready(&state)
        let newer = try ready(&state,entries:[(2,"https://meet.example/new")])
        _ = try state.stop(.init(peer:newer,tabID:2))
        state.disconnect(newer)
        XCTAssertTrue(state.automaticStarts(microphone:false).isEmpty)
        _ = try ready(&state,entries:[(2,"https://meet.example/new")])
        XCTAssertTrue(state.automaticStarts(microphone:false).isEmpty)
    }
    func testFirstStatusBindsBeforeAudioRegistrationAndDisconnectedStopUsesOriginalURL() throws {
        for returningURL in ["https://meet.example/old","https://meet.example/new"] {
            var state = state(); let peer = try ready(&state)
            try send(status("original"),&state,peer)
            state.setRetainedCaptureIDs([]) // Audio registration has not happened.
            state.disconnect(peer)
            state.rememberUserStop(captureID:"original")
            _ = try ready(&state,entries:[(2,returningURL)])
            XCTAssertEqual(state.automaticStarts(microphone:false).count,returningURL.hasSuffix("/old") ? 0 : 1)
        }
    }
    func testNavigationBeforeStartResultStillBindsTheRequestedOriginalURL() throws {
        var state = state(); let peer = try ready(&state)
        let start = try state.start(.init(peer:peer,tabID:2),microphone:false)
        try meetings([(2,"https://meet.example/new")],&state,peer)
        try send(["type":"result","requestId":start.id,"ok":true,"status":status("original")],&state,peer)
        state.disconnect(peer); state.rememberUserStop(captureID:"original")
        _ = try ready(&state,entries:[(2,"https://meet.example/new")])
        XCTAssertEqual(state.automaticStarts(microphone:false).count,1)
    }
    func testUserStopDuringAutomaticStopIsRememberedBeforeBusyCheck() throws {
        var state = state(); let peer = try ready(&state)
        try send(status("original"),&state,peer)
        let key = BrowserMeetingKey(peer:peer,tabID:2)
        XCTAssertNotNil(try state.stop(key,captureID:"original",userInitiated:false))
        XCTAssertNil(try state.stop(key,captureID:"original"))
        state.disconnect(peer); _ = try ready(&state)
        XCTAssertTrue(state.automaticStarts(microphone:false).isEmpty)
    }
    func testAutomaticStopAndFailedStartAreNotLearnedAcrossReconnect() throws {
        for automaticStop in [false,true] {
            var state = state(); let peer = try ready(&state)
            if automaticStop { _ = try state.stop(.init(peer:peer,tabID:2),userInitiated:false) }
            else { _ = state.automaticStarts(microphone:false) }
            state.disconnect(peer); _ = try ready(&state)
            XCTAssertEqual(state.rememberedStopCount,0)
            XCTAssertEqual(state.automaticStarts(microphone:false).count,1)
        }
    }
    func testDisconnectedCaptureInsertionsShareTheBoundedStoreAndUnknownURLIsNeverWildcard() throws {
        var state = state()
        for tab in 0..<280 {
            let peer = try ready(&state,entries:[(tab,"https://meet.example/\(tab)")])
            try send(status("capture-\(tab)",tab:tab),&state,peer)
            state.disconnect(peer)
            state.rememberUserStop(captureID:"capture-\(tab)")
            XCTAssertLessThanOrEqual(state.rememberedStopCount,256)
        }
        state.rememberUserStop(captureID:"never-reported")
        _ = try ready(&state,entries:[(900,"https://meet.example/new")])
        XCTAssertEqual(state.automaticStarts(microphone:false).map(\.key.tabID),[900])
    }
    func testExplicitRecordOverridesTheUsersPreviousStop() throws {
        var state = state(); let peer = try ready(&state)
        let key = BrowserMeetingKey(peer:peer,tabID:2)
        let stop = try XCTUnwrap(state.stop(key))
        try send(["type":"result","requestId":stop.id,"ok":true,"status":status()],&state,peer)
        _ = try state.start(key,microphone:false)
        XCTAssertEqual(state.rememberedStopCount,0)
    }
    func testKernelIdentityAndMetadataValidation() throws {
        let current = try XCTUnwrap(BrowserInstance.process(getpid()))
        XCTAssertEqual(current.isAlive,true)
        XCTAssertEqual(BrowserInstance(pid:current.pid,startSeconds:current.startSeconds+1).isAlive,false)
        XCTAssertTrue(BrowserInstance.isBrowserPath("/tmp/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing"))
        XCTAssertFalse(BrowserInstance.isBrowserPath("/bin/zsh"))
        let peer = BrowserPeer(id:UUID(),role:.control,browser:"Chrome",browserInstance:current)
        XCTAssertEqual(try JSONDecoder().decode(BrowserPeer.self,from:JSONEncoder().encode(peer)).browserInstance,current)
        let legacy = "{\"version\":1,\"id\":\"\(UUID().uuidString)\",\"role\":\"control\"}"
        XCTAssertNil(try JSONDecoder().decode(BrowserPeer.self,from:Data(legacy.utf8)).browserInstance)
        for json in ["{\"pid\":1,\"startSeconds\":1,\"startMicroseconds\":0}","{\"pid\":2,\"startSeconds\":1,\"startMicroseconds\":1000000}"] {
            XCTAssertThrowsError(try JSONDecoder().decode(BrowserInstance.self,from:Data(json.utf8)))
        }
    }
}
