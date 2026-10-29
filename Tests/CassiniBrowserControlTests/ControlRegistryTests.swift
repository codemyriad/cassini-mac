// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
import Foundation
import CassiniKit
@testable import CassiniBrowserControl

final class ControlRegistryTests: XCTestCase {
    func testTransientZeroDiscoveryCannotArmAnActiveCallForAutoRestart() throws {
        var state = BrowserControlRegistry(); try ready(&state)
        try send(status([2]),&state)
        try send(["type":"meetings","meetings":[["tabId":2,"title":"Wake-up","url":"https://meet.example/2","sourceCount":0]]],&state)
        // The extension's own Stop reports status; it does not call the app's
        // explicit stop(), which would independently re-arm suppression.
        try send(status([]),&state)
        try meetings([2],&state)
        XCTAssertTrue(state.automaticStarts(microphone:true).isEmpty)
    }
    func testTransientZeroDiscoveryPreservesRetainedInterruptedCallSuppression() throws {
        var state = BrowserControlRegistry(); try ready(&state)
        state.setRetainedCaptureIDs(["capture-2"])
        var snapshot = status([])
        snapshot["interrupted"] = [["recording":false,"tabId":2,"captureId":"capture-2","path":NSNull(),"message":"Interrupted"]]
        try send(snapshot,&state)
        try meetings([],&state)
        state.setRetainedCaptureIDs([])
        try send(status([]),&state)
        try meetings([2],&state)
        XCTAssertTrue(state.automaticStarts(microphone:true).isEmpty)
    }
    func testCommandSnapshotsRespectIssueOrderWithoutAnInterveningStatus() throws {
        for reversed in [false,true] {
            var state = BrowserControlRegistry(); try ready(&state,tabs:[2,3])
            let requests = state.startAll(microphone:true)
            if reversed {
                try result(requests[1],&state,status:status([2,3]))
                try result(requests[0],&state,status:status([2]))
            } else {
                try result(requests[0],&state,status:status([2]))
                try result(requests[1],&state,status:status([2,3]))
            }
            XCTAssertEqual(state.snapshots.first?.captures.map { $0.key.tabID },[2,3])
        }
    }
    func testResultSnapshotIncludesRetainedInterruptedCaptures() throws {
        var state = BrowserControlRegistry(); try ready(&state)
        let request = try XCTUnwrap(state.startAll(microphone:true).first)
        state.setRetainedCaptureIDs(["capture-2"])
        var snapshot = status([])
        snapshot["interrupted"] = [["recording":false,"tabId":2,"captureId":"capture-2","path":NSNull(),"message":"Interrupted"]]
        try result(request,&state,ok:false,status:snapshot)
        XCTAssertEqual(state.snapshots.first?.interrupted.first?.captureID,"capture-2")
    }
    func testBatchUsesEachMeetingsMicrophoneChoice() throws {
        var state = BrowserControlRegistry(); try ready(&state,tabs:[2,3])
        let requests = state.startAll(microphone:true,choices:[.init(peer:peer,tabID:2):false])
        XCTAssertEqual(requests.count,2)
        for request in requests { XCTAssertEqual(try JSONParser.parse(request.data)["microphone"]?.bool,request.key.tabID == 3) }
    }
    func testRecoveredWorkerCannotRestartTheSameCallWhileItsOwnedFolderUsesFallback() throws {
        var state = BrowserControlRegistry()
        state.setRetainedCaptureIDs(["capture-2"])
        try hello(&state); try meetings([2,3],&state)
        var snapshot = status([])
        snapshot["interrupted"] = [["recording":false,"tabId":2,"captureId":"capture-2","path":"/untrusted-advisory","message":"Interrupted"]]
        try send(snapshot,&state)
        XCTAssertEqual(state.snapshots.first?.interrupted.first?.captureID,"capture-2")
        XCTAssertTrue(state.snapshots.first?.captures.isEmpty == true)
        XCTAssertThrowsError(try state.start(.init(peer:peer,tabID:2),microphone:true))
        XCTAssertEqual(state.automaticStarts(microphone:true).map { $0.key.tabID },[3])
        state.setRetainedCaptureIDs([])
        XCTAssertTrue(state.automaticStarts(microphone:true).isEmpty,"Saving fallback must not auto-restart the same call")
        XCTAssertEqual(try state.start(.init(peer:peer,tabID:2),microphone:false).key.tabID,2,"Explicit Record may start again after Stop")
    }
    func testRetainedCaptureIdentityDoesNotSuppressSameTabInAnotherProfile() throws {
        var state = BrowserControlRegistry(); try hello(&state); try meetings([2],&state)
        var snapshot = status([])
        snapshot["interrupted"] = [["recording":false,"tabId":2,"captureId":"retained","path":NSNull(),"message":"Interrupted"]]
        try send(snapshot,&state)
        state.setRetainedCaptureIDs(["retained"])
        let other = UUID(); try hello(&state,peer:other); try meetings([2],&state,peer:other); try send(status([]),&state,peer:other)
        XCTAssertEqual(state.startAll(microphone:false).map { $0.key.peer },[other])
    }
    let peer = UUID()
    func send(_ value: [String:Any], _ state: inout BrowserControlRegistry, peer: UUID? = nil) throws {
        try state.receive(JSONSerialization.data(withJSONObject:value),from:peer ?? self.peer)
    }
    func hello(_ state: inout BrowserControlRegistry, peer: UUID? = nil, independent: Bool = true) throws {
        let id = peer ?? self.peer
        try state.connect(.init(id:id,role:.control,browser:"Chrome"))
        try send(["type":"hello","version":1,"capabilities":independent ? ["independent-sessions-v1"] : []],&state,peer:id)
    }
    func meetings(_ tabs: [Int], _ state: inout BrowserControlRegistry, peer: UUID? = nil) throws {
        try send(["type":"meetings","meetings":tabs.map { ["tabId":$0,"title":"Meeting \($0)","url":"https://meet.example/\($0)","sourceCount":1] }],&state,peer:peer)
    }
    func status(_ tabs: [Int], sessions: Bool = true) -> [String:Any] {
        var value: [String:Any] = ["type":"status","recording":!tabs.isEmpty,"tabId":tabs.first.map { $0 as Any } ?? NSNull(),"path":NSNull(),"message":"Ready"]
        if sessions { value["sessions"] = tabs.map { ["recording":true,"tabId":$0,"captureId":"capture-\($0)","path":"/advisory/\($0)","message":"Recording","tracks":1,"stopping":false] } }
        return value
    }
    func ready(_ state: inout BrowserControlRegistry, tabs: [Int] = [2], independent: Bool = true) throws {
        try hello(&state,independent:independent); try meetings(tabs,&state); try send(status([]),&state)
    }
    func result(_ request: BrowserControlRequest, _ state: inout BrowserControlRegistry, ok: Bool = true, status: [String:Any]? = nil) throws {
        var json: [String:Any] = ["type":"result","requestId":request.id,"ok":ok]
        if let status { json["status"] = status }
        try send(json,&state,peer:request.key.peer)
    }
    func testExplicitRecordNamespacesTwoProfilesAndPreservesMicrophoneChoice() throws {
        var state = BrowserControlRegistry(); try ready(&state)
        let other = UUID(); try hello(&state,peer:other); try meetings([2],&state,peer:other); try send(status([]),&state,peer:other)
        let requests = state.startAll(microphone:false)
        XCTAssertEqual(requests.count,2); XCTAssertEqual(Set(requests.map(\.id)).count,2)
        XCTAssertEqual(Set(requests.map { $0.key.peer }),Set([peer,other]))
        for request in requests {
            let json = try JSONParser.parse(request.data)
            XCTAssertEqual(json["tabId"]?.int,2); XCTAssertEqual(json["independent"]?.bool,true)
            XCTAssertEqual(json["captureLocal"]?.bool,false); XCTAssertEqual(json["microphone"]?.bool,false)
            XCTAssertEqual(json["mode"]?.string,"tracks"); XCTAssertNil(json["path"])
        }
        XCTAssertTrue(state.startAll(microphone:true).isEmpty)
    }
    func testFirstStatusReconcilesExistingCaptureBeforeAutoStartAndNeverRestartsIt() throws {
        var state = BrowserControlRegistry(); try hello(&state); try meetings([2],&state)
        XCTAssertTrue(state.automaticStarts(microphone:true).isEmpty)
        XCTAssertThrowsError(try state.start(.init(peer:peer,tabID:2),microphone:true))
        try send(status([2]),&state); XCTAssertTrue(state.automaticStarts(microphone:true).isEmpty)
        try send(status([]),&state); XCTAssertTrue(state.automaticStarts(microphone:true).isEmpty)
        try meetings([],&state); try meetings([2],&state)
        XCTAssertEqual(state.automaticStarts(microphone:true).count,1)
    }
    func testEmptySessionsOverridesLegacyTopLevelRecording() throws {
        var state = BrowserControlRegistry(); try hello(&state); try meetings([2],&state)
        var value = status([2]); value["sessions"] = [] as [Any]
        try send(value,&state)
        XCTAssertTrue(try XCTUnwrap(state.snapshots.first).captures.isEmpty)
        XCTAssertEqual(state.startAll(microphone:true).count,1)
    }
    func testStopCancelsPendingStartOnlyOnceAndDoesNotTargetOtherPeer() throws {
        var state = BrowserControlRegistry(); try ready(&state,tabs:[2,3])
        _ = state.startAll(microphone:true)
        let key = BrowserMeetingKey(peer:peer,tabID:2)
        let stop = try XCTUnwrap(state.stop(key)); XCTAssertEqual(stop.action,.stop)
        XCTAssertEqual(try JSONParser.parse(stop.data)["tabId"]?.int,2)
        XCTAssertNil(try state.stop(key))
        XCTAssertEqual(state.stopAll().map { $0.key.tabID },[3])
    }
    func testAutoStartFailureDoesNotLoopButFutureMeetingCanStart() throws {
        var state = BrowserControlRegistry(); try ready(&state)
        let request = try XCTUnwrap(state.automaticStarts(microphone:true).first)
        try result(request,&state,ok:false)
        XCTAssertTrue(state.automaticStarts(microphone:true).isEmpty)
        try meetings([],&state); try meetings([2],&state)
        XCTAssertEqual(state.automaticStarts(microphone:false).count,1)
        XCTAssertEqual(state.outcomes.last?.ok,false)
    }
    func testOutOfOrderResultsCorrelateByRequestAndDoNotResurrectNewerStatus() throws {
        var state = BrowserControlRegistry(); try ready(&state,tabs:[2,3])
        let starts = state.startAll(microphone:true)
        try send(status([2,3]),&state); try send(status([]),&state)
        try result(starts[1],&state,status:status([2,3]))
        try result(starts[0],&state,status:status([2]))
        XCTAssertEqual(state.outcomes.map(\.requestID),[starts[1].id,starts[0].id])
        XCTAssertTrue(try XCTUnwrap(state.snapshots.first).captures.isEmpty)
    }
    func testControlLossDropsDiscoveryWithoutInventingStopAndLeavesOtherPeerUsable() throws {
        var state = BrowserControlRegistry(); try ready(&state)
        let first = try XCTUnwrap(state.startAll(microphone:true).first)
        let other = UUID(); try hello(&state,peer:other); try meetings([2],&state,peer:other); try send(status([]),&state,peer:other)
        state.disconnect(peer)
        XCTAssertEqual(state.outcomes.last?.requestID,first.id)
        XCTAssertEqual(state.snapshots.count,1)
        XCTAssertEqual(state.startAll(microphone:true).first?.key.peer,other)
    }
    func testLegacyPeerCanStopExistingCaptureButCannotStartIndependentCapture() throws {
        var state = BrowserControlRegistry(); try ready(&state,independent:false)
        XCTAssertTrue(state.startAll(microphone:true).isEmpty)
        try send(status([2],sessions:false),&state)
        let stop = try XCTUnwrap(state.stop(.init(peer:peer,tabID:2)))
        XCTAssertNil(try JSONParser.parse(stop.data)["independent"])
        XCTAssertEqual(try JSONParser.parse(stop.data)["tabId"]?.int,2)
    }
    func testMalformedReplacementIsAtomicAndUnknownMessagesOrResultsAreHarmless() throws {
        var state = BrowserControlRegistry(); try ready(&state)
        for raw in ["{\"type\":\"meetings\",\"meetings\":[{\"tabId\":true}]}",
                    "{\"type\":\"status\",\"recording\":false,\"tabId\":1.0,\"path\":null,\"message\":\"Ready\"}",
                    "{\"type\":\"status\",\"recording\":false,\"tabId\":null,\"path\":null,\"message\":\"Ready\",\"sessions\":false}"] {
            XCTAssertThrowsError(try state.receive(Data(raw.utf8),from:peer))
            XCTAssertEqual(state.snapshots.first?.meetings.count,1)
            XCTAssertTrue(state.snapshots.first?.reconciled == true)
        }
        try send(["type":"result","requestId":42,"ok":true],&state)
        try send(["type":"result","requestId":"old","ok":true],&state)
        try send(["type":"future","action":"start","tabId":2],&state)
        XCTAssertTrue(state.outcomes.isEmpty)
    }
    func testStopAllIntentSurvivesThe128CommandWindow() throws {
        var state = BrowserControlRegistry(); try ready(&state,tabs:Array(0..<100))
        let starts = state.startAll(microphone:true); XCTAssertEqual(starts.count,100)
        var stops = state.stopAll(); XCTAssertEqual(stops.count,28)
        for request in starts { try result(request,&state) }
        stops += state.drainStops()
        XCTAssertEqual(stops.count,100); XCTAssertEqual(Set(stops.map(\.key)).count,100)
        for request in stops { try result(request,&state) }
        XCTAssertTrue(state.drainStops().isEmpty)
    }
}
