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
        state.setLostCalls([.init(instance:nil,peer:peer,tabID:2,callGeneration:"call-A")])
        XCTAssertTrue(state.automaticStarts(microphone:true).isEmpty)
        // Another call in the same tab is a new call: it may start.
        try meeting(&state,peer,generation:"call-B")
        XCTAssertEqual(state.automaticStarts(microphone:true).map(\.key.tabID),[2])
    }
    func testTheSuppressionFollowsTheBrowserAcrossAControlReconnect() throws {
        var state = BrowserControlRegistry()
        let instance = BrowserInstance(pid:4242,startSeconds:1_793_000_000), old = UUID(), new = UUID()
        try ready(&state,old,instance:instance,generation:"call-A")
        state.disconnect(old)
        state.setLostCalls([.init(instance:instance,peer:old,tabID:2,callGeneration:"call-A")])
        try ready(&state,new,instance:instance,generation:"call-A")
        XCTAssertTrue(state.automaticStarts(microphone:true).isEmpty,"the frozen companion's call is resumed, not started again")
        state.setLostCalls([])
        XCTAssertEqual(state.automaticStarts(microphone:true).map(\.key.tabID),[2])
    }
}
