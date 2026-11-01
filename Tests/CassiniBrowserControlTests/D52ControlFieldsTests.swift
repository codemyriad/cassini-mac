// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
import Foundation
import CassiniKit
@testable import CassiniBrowserControl

/// D52 M3/M6 control fields: multi-stream-v1 rows and status, and commands that
/// name their call (Start) and capture (Stop). Older extensions see neither.
final class D52ControlFieldsTests: XCTestCase {
    let peer = UUID()
    private func send(_ value: [String:Any], _ state: inout BrowserControlRegistry) throws {
        try state.receive(JSONSerialization.data(withJSONObject:value),from:peer)
    }
    private func ready(_ state: inout BrowserControlRegistry, capabilities: [String]) throws {
        try state.connect(.init(id:peer,role:.control,browser:"Chrome"))
        try send(["type":"hello","version":1,"capabilities":capabilities],&state)
        try send(["type":"meetings","meetings":[["tabId":2,"title":"Call","url":"https://meet.example/a","sourceCount":1,
            "sourceCountKnown":false,"callGeneration":"call-A","documentGeneration":"doc-1"]]],&state)
        try send(["type":"status","recording":false,"tabId":NSNull(),"path":NSNull(),"message":"Ready","sessions":[]],&state)
    }
    private func capture(_ state: inout BrowserControlRegistry, id: String) throws {
        try send(["type":"status","recording":true,"tabId":2,"path":NSNull(),"message":"Recording","sessions":[
            ["recording":true,"tabId":2,"captureId":id,"path":NSNull(),"message":"Recording","tracks":1,"stopping":false,
             "callGeneration":"call-A","failedSources":["guest-root"]]]],&state)
    }
    func testMultiStreamRowsStatusAndEchoedCommandFields() throws {
        var state = BrowserControlRegistry()
        try ready(&state,capabilities:["independent-sessions-v1","page-state-v1","multi-stream-v1","resume-capture-v1"])
        let snapshot = try XCTUnwrap(state.snapshots.first)
        XCTAssertTrue(snapshot.supportsMultiStream); XCTAssertTrue(snapshot.supportsResume)
        let row = try XCTUnwrap(snapshot.meetings.first)
        XCTAssertFalse(row.sourceCountKnown); XCTAssertEqual(row.callGeneration,"call-A"); XCTAssertEqual(row.documentGeneration,"doc-1")
        let start = try state.start(.init(peer:peer,tabID:2),microphone:true)
        XCTAssertEqual(try JSONParser.parse(start.data)["callGeneration"]?.string,"call-A")
        let long = String(repeating:"c",count:200)
        try capture(&state,id:long)
        let status = try XCTUnwrap(state.snapshots.first?.captures.first)
        XCTAssertEqual(status.captureID,long); XCTAssertEqual(status.callGeneration,"call-A"); XCTAssertEqual(status.failedSources,["guest-root"])
        let stop = try XCTUnwrap(try state.stop(.init(peer:peer,tabID:2)))
        XCTAssertEqual(try JSONParser.parse(stop.data)["captureId"]?.string,long)
    }
    func testOlderExtensionsGetNeitherEcho() throws {
        var state = BrowserControlRegistry()
        try ready(&state,capabilities:["independent-sessions-v1","page-state-v1"])
        let row = try XCTUnwrap(state.snapshots.first?.meetings.first)
        XCTAssertTrue(row.sourceCountKnown); XCTAssertNil(row.callGeneration)
        let start = try state.start(.init(peer:peer,tabID:2),microphone:true)
        XCTAssertNil(try JSONParser.parse(start.data)["callGeneration"])
        try capture(&state,id:"capture-1")
        let stop = try XCTUnwrap(try state.stop(.init(peer:peer,tabID:2)))
        XCTAssertNil(try JSONParser.parse(stop.data)["captureId"])
    }
    func testMalformedGenerationIsRejected() throws {
        var state = BrowserControlRegistry()
        try state.connect(.init(id:peer,role:.control,browser:"Chrome"))
        try send(["type":"hello","version":1,"capabilities":["independent-sessions-v1","multi-stream-v1"]],&state)
        XCTAssertThrowsError(try send(["type":"meetings","meetings":[["tabId":2,"title":"Call","url":"https://meet.example/a","sourceCount":1,"callGeneration":""]]],&state))
    }
}
