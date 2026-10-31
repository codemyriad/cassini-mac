// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
import Foundation
import Darwin
@testable import CassiniBrowserControl

/// Uses only the pre-D43 API, so the same assertion runs against original main.
final class StopReconnectRegressionTests: XCTestCase {
    private func ready(_ state: inout BrowserControlRegistry) throws -> UUID {
        var process = proc_bsdinfo()
        XCTAssertEqual(proc_pidinfo(getpid(),PROC_PIDTBSDINFO,0,&process,Int32(MemoryLayout.size(ofValue:process))),Int32(MemoryLayout.size(ofValue:process)))
        let id = UUID()
        let metadata: [String:Any] = ["version":1,"id":id.uuidString,"role":"control","browser":"Chrome",
            "browserInstance":["pid":getpid(),"startSeconds":process.pbi_start_tvsec,"startMicroseconds":process.pbi_start_tvusec]]
        try state.connect(JSONDecoder().decode(BrowserPeer.self,from:JSONSerialization.data(withJSONObject:metadata)))
        for message: [String:Any] in [
            ["type":"hello","version":1,"capabilities":["independent-sessions-v1"]],
            ["type":"meetings","meetings":[["tabId":2,"title":"Call","url":"https://meet.example/call","sourceCount":1]]],
            ["type":"status","recording":false,"tabId":NSNull(),"path":NSNull(),"message":"Ready","sessions":[]]] {
            try state.receive(JSONSerialization.data(withJSONObject:message),from:id)
        }
        return id
    }
    func testUserStopDoesNotAutoStartAfterControlReconnect() throws {
        var state = BrowserControlRegistry()
        let first = try ready(&state)
        _ = try state.stop(.init(peer:first,tabID:2))
        state.disconnect(first)
        _ = try ready(&state)
        XCTAssertTrue(state.automaticStarts(microphone:false).isEmpty,"A new Native Messaging UUID must not undo the user's Stop")
    }
    func testStopRequestedAfterControlDisconnectDoesNotAutoStartOnReturn() throws {
        var state = BrowserControlRegistry()
        let first = try ready(&state)
        state.disconnect(first)
        _ = try? state.stop(.init(peer:first,tabID:2))
        _ = try ready(&state)
        XCTAssertTrue(state.automaticStarts(microphone:false).isEmpty,"Remember user intent before rejecting an unavailable transport")
    }
}
