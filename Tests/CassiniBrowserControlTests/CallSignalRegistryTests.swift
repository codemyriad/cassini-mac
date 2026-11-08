// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
import CassiniKit
@testable import CassiniBrowserControl

final class CallSignalRegistryTests: XCTestCase {
    private let id = UUID()
    private func send(_ packet: [String:Any], _ state: inout BrowserControlRegistry) throws {
        try state.receive(JSONSerialization.data(withJSONObject:packet),from:id)
    }
    private func snapshot(_ sequence: Int = 0, state: String = "active", remote: String = "mixed") -> [String:Any] {
        ["type":"callSignals","browserInstance":"profile-A","sequence":sequence,"tabs":[[
            "tabId":2,"url":"https://call.example/","documentGeneration":"document-A","remoteAudio":remote,
            "callEvidence":["state":state,"reason":state == "active" ? "activeCall" : "callEnded",
                            "adapter":["name":"Synthetic call","version":"1"],"callGeneration":"call-A"]]]]
    }
    private func hello(_ state: inout BrowserControlRegistry) throws {
        try state.connect(.init(id:id,role:.control,browser:"Chrome"))
        try send(["type":"hello","version":1,"capabilities":["call-signals-v1","multi-stream-v1","independent-sessions-v1"]],&state)
    }
    func testConfigurationSequenceProfileAndAtomicReplacement() throws {
        var state = BrowserControlRegistry(); try hello(&state)
        XCTAssertThrowsError(try send(snapshot(),&state))
        try send(["type":"configured","capabilities":["call-signals-v1"]],&state)
        try send(snapshot(5),&state)
        try send(snapshot(4,state:"inactive"),&state)
        XCTAssertEqual(state.snapshots.first?.callSignals?.sequence,5)
        XCTAssertEqual(state.snapshots.first?.callSignals?.tabs.first?.state,"active")
        var invalid = snapshot(6)
        let rows = invalid["tabs"] as! [[String:Any]]; invalid["tabs"] = rows + rows
        XCTAssertThrowsError(try send(invalid,&state))
        XCTAssertEqual(state.snapshots.first?.callSignals?.sequence,5)
        var changed = snapshot(6); changed["browserInstance"] = "another profile"
        XCTAssertThrowsError(try send(changed,&state))
        try send(["type":"callSignals","browserInstance":"profile-A","sequence":6,"tabs":[]],&state)
        XCTAssertTrue(state.snapshots.first?.callSignals?.tabs.isEmpty == true)
        try send(["type":"configured","capabilities":[]],&state)
        XCTAssertNil(state.snapshots.first?.callSignals)
        XCTAssertThrowsError(try send(snapshot(7),&state))
    }
    func testNewStableProfilePeerFencesLegacyAdmissionEvenAfterItDisconnects() throws {
        var state = BrowserControlRegistry(); try hello(&state)
        try send(["type":"configured","capabilities":["call-signals-v1"]],&state)
        try send(snapshot(0,remote:"separated"),&state)
        try send(["type":"meetings","meetings":[["tabId":2,"title":"Call","url":"https://call.example/","sourceCount":1,"heard":true,"callGeneration":"call-A"]]],&state)
        try send(["type":"status","recording":false,"tabId":NSNull(),"path":NSNull(),"message":"Ready","sessions":[]],&state)
        let replacement = UUID(); try state.connect(.init(id:replacement,role:.control,browser:"Chrome"))
        let packets: [[String:Any]] = [["type":"hello","version":1,"capabilities":["call-signals-v1"]],
                                     ["type":"configured","capabilities":["call-signals-v1"]],snapshot(0)]
        for packet in packets {
            try state.receive(JSONSerialization.data(withJSONObject:packet),from:replacement)
        }
        XCTAssertEqual(state.snapshots.map(\.id),[replacement])
        XCTAssertTrue(state.automaticStarts(microphone:false).isEmpty)
        XCTAssertThrowsError(try state.start(.init(peer:id,tabID:2),microphone:false))
        state.disconnect(replacement)
        try send(snapshot(1,remote:"separated"),&state)
        XCTAssertTrue(state.snapshots.isEmpty,"An obsolete peer cannot reclaim a disconnected replacement’s stable profile")
        XCTAssertTrue(state.automaticStarts(microphone:false).isEmpty)
    }
    func testMixedRowsCannotEnterLegacyBrowserStartAndRouteOwnerBlocksSeparatedReclassification() throws {
        var state = BrowserControlRegistry(); try hello(&state)
        try send(["type":"configured","capabilities":["call-signals-v1"]],&state)
        try send(snapshot(),&state)
        try send(["type":"meetings","meetings":[["tabId":2,"title":"Call","url":"https://call.example/","sourceCount":1,"heard":true,"documentGeneration":"document-A","callGeneration":"call-A"]]],&state)
        try send(["type":"status","recording":false,"tabId":NSNull(),"path":NSNull(),"message":"Ready","sessions":[]],&state)
        XCTAssertTrue(state.automaticStarts(microphone:false).isEmpty)
        XCTAssertThrowsError(try state.start(.init(peer:id,tabID:2),microphone:false))
        state.signalOwnedCalls = [.init(instance:"profile-A",tab:2,document:"document-A",generation:"call-A")]
        try send(snapshot(1,remote:"separated"),&state)
        XCTAssertTrue(state.automaticStarts(microphone:false).isEmpty)
        XCTAssertThrowsError(try state.start(.init(peer:id,tabID:2),microphone:false))
        // A different profile must not be suppressed by a coincident tab/generation.
        state.signalOwnedCalls = [.init(instance:"profile-B",tab:2,document:"document-A",generation:"call-A")]
        XCTAssertEqual(state.automaticStarts(microphone:false).count,1)
    }
}
