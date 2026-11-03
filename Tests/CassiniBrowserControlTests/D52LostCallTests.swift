// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
import Foundation
import CassiniKit
@testable import CassiniBrowserControl

/// D52.5: a call that has a recording on system/lost (its audio transport closed) is asked to
/// resume that recording and is never auto-Started afresh, also after a control reconnect.
final class D52LostCallTests: XCTestCase {
    private func send(_ value: [String:Any], _ state: inout BrowserControlRegistry, _ peer: UUID) throws {
        try state.receive(JSONSerialization.data(withJSONObject:value),from:peer)
    }
    private func ready(_ state: inout BrowserControlRegistry, _ peer: UUID, instance: BrowserInstance?, generation: String) throws {
        try state.connect(.init(id:peer,role:.control,browser:"Chrome",browserInstance:instance))
        try send(["type":"hello","version":1,"capabilities":["independent-sessions-v1","multi-stream-v1","resume-capture-v1"]],&state,peer)
        try meeting(&state,peer,generation:generation)
        try send(["type":"status","recording":false,"tabId":NSNull(),"path":NSNull(),"message":"Ready","sessions":[]],&state,peer)
    }
    private func meeting(_ state: inout BrowserControlRegistry, _ peer: UUID, generation: String) throws {
        try send(["type":"meetings","meetings":[["tabId":2,"title":"Call","url":"https://meet.example/2","sourceCount":1,"callGeneration":generation]]],&state,peer)
    }

    func testACallWithALostRecordingIsNeverAutoStartedAfresh() throws {
        var state = BrowserControlRegistry(), peer = UUID()
        try ready(&state,peer,instance:nil,generation:"call-A")
        state.setLostCalls([.init(tabID:2,callGeneration:"call-A")])
        XCTAssertTrue(state.automaticStarts(microphone:true).isEmpty)
        XCTAssertTrue(state.startAll(microphone:true).isEmpty,"Record all skips the recording call")
        // Another call in the same tab is a new call: it may start.
        try meeting(&state,peer,generation:"call-B")
        XCTAssertEqual(state.automaticStarts(microphone:true).map(\.key.tabID),[2])
    }
    func testTheSuppressionFollowsTheBrowserAcrossAControlReconnect() throws {
        var state = BrowserControlRegistry()
        let instance = BrowserInstance(pid:4242,startSeconds:1_793_000_000), old = UUID(), new = UUID()
        try ready(&state,old,instance:instance,generation:"call-A")
        state.disconnect(old)
        state.setLostCalls([.init(tabID:2,callGeneration:"call-A")])
        try ready(&state,new,instance:instance,generation:"call-A")
        XCTAssertTrue(state.automaticStarts(microphone:true).isEmpty,"the frozen companion's call is resumed, not started again")
        state.setLostCalls([])
        XCTAssertEqual(state.automaticStarts(microphone:true).map(\.key.tabID),[2])
    }

    /// #113 review r2: a D49 stand-in whose take-over committed is its call's recording. After
    /// its transport closes and the control connection reconnects, it follows the call to the
    /// new peer and suppresses auto-Start and Record all, exactly like a Chromium capture. A
    /// stand-in whose take-over is still pending is a native recording and does neither.
    func testAnAdoptedStandInFollowsItsCallAcrossAControlReconnect() throws {
        var state = BrowserControlRegistry()
        let instance = BrowserInstance(pid:4242,startSeconds:1_793_000_000), old = UUID(), new = UUID()
        try ready(&state,old,instance:instance,generation:"call-A")
        let key = try XCTUnwrap(state.snapshots.first { $0.id == old }?.meetings.first?.key)
        let adopted = [CaptureEvent(atMs:0,type:"selection",reason:"start",me:true,others:true),
                       CaptureEvent(atMs:0,type:"othersSource",source:"system",reason:"missing"),
                       CaptureEvent(atMs:1000,type:"othersSource",source:"browser",reason:"callConnected"),
                       CaptureEvent(atMs:5000,type:"othersSource",source:"none",reason:"lost"),
                       CaptureEvent(atMs:5100,type:"othersSource",source:"system",reason:"lost")]
        let pending = Array(adopted.prefix(2))
        XCTAssertTrue(BrowserCallPolicy.followsCall(source:"macos",keyed:true,events:adopted))
        XCTAssertFalse(BrowserCallPolicy.followsCall(source:"macos",keyed:true,events:pending))
        let lost = try XCTUnwrap(BrowserCallPolicy.lostCall(source:"macos",key:key,callGeneration:"call-A",recording:true,transportAlive:false,events:adopted))
        XCTAssertEqual(lost,.init(tabID:2,callGeneration:"call-A"))
        XCTAssertNil(BrowserCallPolicy.lostCall(source:"macos",key:key,callGeneration:"call-A",recording:true,transportAlive:false,events:pending))
        XCTAssertNil(BrowserCallPolicy.lostCall(source:"macos",key:key,callGeneration:"call-A",recording:true,transportAlive:true,events:adopted))
        // The control connection drops and the same browser reconnects on a new peer.
        state.disconnect(old)
        state.setLostCalls([lost])
        try ready(&state,new,instance:instance,generation:"call-A")
        let meetings = state.snapshots.filter(\.reconciled).flatMap(\.meetings)
        let rebound = BrowserCallPolicy.lostCallMeeting(source:"macos",key:key,callGeneration:"call-A",transportAlive:false,events:adopted,meetings:meetings)
        XCTAssertEqual(rebound?.peer,new,"the recording follows its call to the new control peer")
        XCTAssertEqual(rebound?.tabID,2)
        XCTAssertNil(BrowserCallPolicy.lostCallMeeting(source:"macos",key:key,callGeneration:"call-A",transportAlive:false,events:pending,meetings:meetings))
        XCTAssertTrue(state.automaticStarts(microphone:true).isEmpty,"no second folder by auto-Start")
        XCTAssertTrue(state.startAll(microphone:true).isEmpty,"no second folder by Record all")
    }
}
