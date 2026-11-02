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
    /// The schema bounds captureId and source identities by 200 UTF-8 bytes, not characters:
    /// the extension refuses a Stop that echoes a longer one.
    func testIdentitiesAreBoundedByUTF8Bytes() throws {
        var state = BrowserControlRegistry()
        try ready(&state,capabilities:["independent-sessions-v1","page-state-v1","multi-stream-v1"])
        let wide = String(repeating:"é",count:101) // 101 scalars, 202 bytes
        XCTAssertThrowsError(try capture(&state,id:wide))
        XCTAssertThrowsError(try send(["type":"status","recording":true,"tabId":2,"path":NSNull(),"message":"Recording","sessions":[
            ["recording":true,"tabId":2,"captureId":"capture-1","path":NSNull(),"message":"Recording","failedSources":[wide]]]],&state))
        try capture(&state,id:String(repeating:"é",count:100))
        let stop = try XCTUnwrap(try state.stop(.init(peer:peer,tabID:2)))
        XCTAssertEqual(try JSONParser.parse(stop.data)["captureId"]?.string?.utf8.count,200)
    }
    /// D52 M6: a new call generation in the same tab and URL is a new call. Neither an earlier
    /// automatic attempt nor the user's Stop of the previous call suppresses it.
    func testANewCallGenerationAtTheSameURLStartsAgain() throws {
        var state = BrowserControlRegistry(clock:{ 100 },instanceAlive:{ _ in true })
        try state.connect(.init(id:peer,role:.control,browser:"Chrome",browserInstance:.init(pid:123,startSeconds:42)))
        try send(["type":"hello","version":1,"capabilities":["independent-sessions-v1","page-state-v1","multi-stream-v1"]],&state)
        func row(_ generation: String) throws {
            try send(["type":"meetings","meetings":[["tabId":2,"title":"Call","url":"https://meet.example/a","sourceCount":1,
                "callGeneration":generation]]],&state)
        }
        let idle: [String:Any] = ["type":"status","recording":false,"tabId":NSNull(),"path":NSNull(),"message":"Ready","sessions":[]]
        try row("call-A"); try send(idle,&state)
        let start = try XCTUnwrap(state.automaticStarts(microphone:false).first)
        XCTAssertEqual(try JSONParser.parse(start.data)["callGeneration"]?.string,"call-A")
        try send(["type":"result","requestId":start.id,"ok":true,"status":idle],&state)
        XCTAssertTrue(state.automaticStarts(microphone:false).isEmpty)
        try row("call-B")
        let again = try XCTUnwrap(state.automaticStarts(microphone:false).first)
        XCTAssertEqual(try JSONParser.parse(again.data)["callGeneration"]?.string,"call-B")
        try send(["type":"result","requestId":again.id,"ok":true,"status":idle],&state)
        // The user stops call B; call C in the same tab and URL records again.
        let stop = try XCTUnwrap(state.stop(.init(peer:peer,tabID:2),userInitiated:true))
        try send(["type":"result","requestId":stop.id,"ok":true,"status":idle],&state)
        try row("call-B")
        XCTAssertTrue(state.automaticStarts(microphone:false).isEmpty)
        try row("call-C")
        XCTAssertEqual(state.automaticStarts(microphone:false).count,1)
    }
    func testMalformedGenerationIsRejected() throws {
        var state = BrowserControlRegistry()
        try state.connect(.init(id:peer,role:.control,browser:"Chrome"))
        try send(["type":"hello","version":1,"capabilities":["independent-sessions-v1","multi-stream-v1"]],&state)
        XCTAssertThrowsError(try send(["type":"meetings","meetings":[["tabId":2,"title":"Call","url":"https://meet.example/a","sourceCount":1,"callGeneration":""]]],&state))
    }
}
