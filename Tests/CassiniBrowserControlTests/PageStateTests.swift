// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import XCTest
import os
import CassiniKit
@testable import CassiniBrowserControl

final class PageStateTests: XCTestCase {
    private func send(_ json: [String:Any], _ state: inout BrowserControlRegistry, _ peer: UUID) throws {
        try state.receive(JSONSerialization.data(withJSONObject:json),from:peer)
    }
    private func ready(_ state: inout BrowserControlRegistry, enabled: Bool) throws -> UUID {
        let peer = UUID(); try state.connect(.init(id:peer,role:.control,browser:"Chrome"))
        try send(["type":"hello","version":1,"capabilities": ["independent-sessions-v1"]+(enabled ? ["page-state-v1"] : [])],&state,peer)
        return peer
    }
    private func meetings(_ page: Any? = nil) -> [String:Any] {
        var entry:[String:Any] = ["tabId":2,"title":"Call","url":"https://meet.example/call","sourceCount":1]
        if let page { entry["pageState"] = page }
        return ["type":"meetings","meetings":[entry]]
    }
    private func status(_ page: Any? = nil) -> [String:Any] {
        var entry:[String:Any] = ["tabId":2,"captureId":"one","recording":true,"path":NSNull(),"message":"Recording"]
        if let page { entry["pageState"] = page }
        return ["type":"status","recording":true,"tabId":2,"path":NSNull(),"message":"Recording","sessions":[entry]]
    }
    func testCapabilityScopesPagesAndMissingIsUnknown() throws {
        for enabled in [false,true] {
            var state = BrowserControlRegistry(); let peer = try ready(&state,enabled:enabled)
            try send(meetings("navigating"),&state,peer); try send(status("navigating"),&state,peer)
            let snapshot = try XCTUnwrap(state.snapshots.first)
            XCTAssertEqual(snapshot.supportsPageState,enabled)
            XCTAssertEqual(snapshot.meetings.first?.pageState,enabled ? .navigating : nil)
            XCTAssertEqual(snapshot.captures.first?.pageState,enabled ? .navigating : nil)
            try send(status(),&state,peer)
            XCTAssertNil(state.snapshots.first?.captures.first?.pageState)
        }
    }
    func testClosedEvidenceAndItsObservationTimeSurviveLatePresentSnapshots() throws {
        let clock = OSAllocatedUnfairLock(initialState: TimeInterval(10))
        var state = BrowserControlRegistry(clock:{ clock.withLock { $0 } })
        let peer = try ready(&state,enabled:true)
        clock.withLock { $0 = 20 }
        try send(status("closed"),&state,peer)
        XCTAssertEqual(state.snapshots.first?.captures.first?.pageStateAt,20)

        clock.withLock { $0 = 30 }
        try send(meetings("present"),&state,peer)
        clock.withLock { $0 = 40 }
        try send(status("present"),&state,peer)
        let snapshot = try XCTUnwrap(state.snapshots.first)
        XCTAssertEqual(snapshot.captures.first?.pageState,.closed)
        XCTAssertEqual(snapshot.captures.first?.pageStateAt,20)
        XCTAssertEqual(snapshot.meetings.first?.pageState,.closed)
        XCTAssertEqual(snapshot.meetings.first?.pageStateAt,20)
    }
    func testLegacyIgnoresInvalidPageFieldsButCapablePeerRejectsAtomically() throws {
        for enabled in [false,true] {
            var state = BrowserControlRegistry(); let peer = try ready(&state,enabled:enabled)
            try send(status(),&state,peer)
            if enabled { XCTAssertThrowsError(try send(status(false),&state,peer)) }
            else { try send(status(false),&state,peer) }
            XCTAssertNil(state.snapshots.first?.captures.first?.pageState)
        }
    }
    func testTerminalReasonAndNavigationOptInAreScopedToCapablePeers() throws {
        for enabled in [false,true] {
            var state = BrowserControlRegistry(); let peer = try ready(&state,enabled:enabled)
            try send(meetings("present"),&state,peer)
            try send(["type":"status","recording":false,"tabId":NSNull(),"path":NSNull(),"message":"Ready","sessions":[]],&state,peer)
            let start = try state.start(.init(peer:peer,tabID:2),microphone:false)
            XCTAssertEqual(try JSONParser.parse(start.data)["keepOnNavigation"]?.bool,enabled ? true : nil)
            let stop = try XCTUnwrap(state.stop(start.key,reason:.disk))
            XCTAssertEqual(try JSONParser.parse(stop.data)["reason"]?.string,enabled ? "disk" : nil)
            XCTAssertNil(try state.stop(start.key,reason:.user),"The first in-flight Stop keeps its trigger")
        }
    }
}
