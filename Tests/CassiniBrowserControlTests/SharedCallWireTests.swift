// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import XCTest
@testable import CassiniBrowserControl

final class SharedCallWireTests: XCTestCase {
    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var value: TimeInterval = 0
        var now: TimeInterval {
            get { lock.withLock { value } }
            set { lock.withLock { value = newValue } }
        }
    }
    private func send(_ packet: [String:Any], to state: inout BrowserControlRegistry, peer: UUID) throws {
        try state.receive(JSONSerialization.data(withJSONObject:packet),from:peer)
    }
    func testLiteralWireVectorsThroughTheProductionRegistryAndPolicy() throws {
        let root = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let file = root.appendingPathComponent("browser-protocol/conformance/control/call-lifecycle-wire-vectors.json")
        let vectors = try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:file)) as? [String:Any])
        let cases = try XCTUnwrap(vectors["cases"] as? [[String:Any]])
        XCTAssertEqual(cases.count,4)
        for sample in cases {
            let clock = Clock(), id = UUID(), tab = try XCTUnwrap(sample["tabId"] as? Int)
            var registry = BrowserControlRegistry(clock:{ clock.now }), policy = BrowserCallLifecycle(), system = false
            try registry.connect(.init(id:id,role:.control,browser:"Wire fixture",browserInstance:.init(pid:4321,startSeconds:100)))
            try send(try XCTUnwrap(vectors["hello"] as? [String:Any]),to:&registry,peer:id)
            // Bind the existing capture to its original call, as production
            // does, so changing discovery URL later exercises Stop's guard.
            try send(["type":"meetings","meetings":[["tabId":tab,"title":"Original","url":"https://wire.example/original","sourceCount":1,"heard":true,"pageState":"present"]]],to:&registry,peer:id)
            // The corpus starts with an already owned recording, after hello.
            try send(["type":"status","recording":true,"tabId":tab,"path":"/test/Recording-reload","message":"","pageState":"present","captureId":"reload-capture"],to:&registry,peer:id)
            for step in try XCTUnwrap(sample["steps"] as? [[String:Any]]) {
                let time = Double(try XCTUnwrap(step["atMs"] as? Int))/1000; clock.now = time
                if let packet = step["packet"] as? [String:Any] { try send(packet,to:&registry,peer:id) }
                let peer = try XCTUnwrap(registry.snapshots.first)
                let meeting = peer.meetings.first { $0.key.tabID == tab }
                XCTAssertEqual(peer.captures.first { $0.key.tabID == tab }?.captureID,"reload-capture","Wire evidence cannot erase the owned recording identity")
                let expected = try XCTUnwrap(step["expectEvidence"] as? [String:Any])
                let label = "\(sample["name"] ?? "?") at \(time)"
                // This is the production reader's cache, never expected values
                // or a second JSON-to-evidence parser feeding the policy.
                XCTAssertEqual(meeting?.pageState?.rawValue,expected["pageState"] as? String,label)
                XCTAssertEqual(meeting?.sourceCount ?? 0,expected["sourceCount"] as? Int,label)
                XCTAssertEqual(meeting?.heard ?? false,expected["heard"] as? Bool,label)
                let action = policy.step(now:time,page:meeting?.pageState,sourceCount:meeting?.sourceCount ?? 0,
                                         usingSystem:system,others:true,pageObservedAt:meeting?.pageStateAt)
                var actions: [String] = []
                if let action {
                    switch action {
                    case .fallback: actions = ["fallback"]; system = true
                    case .restore: actions = ["restore"]; system = false
                    case .stop(let reason): actions = ["stop:"+reason.rawValue]
                    }
                }
                XCTAssertEqual(actions,try XCTUnwrap(step["expect"] as? [String]),label)
                let timers = try XCTUnwrap(step["expectTimers"] as? [String:Any])
                XCTAssertEqual(policy.pendingTimers.missing.map { Int(($0*1000).rounded()) },timers["missingAtMs"] as? Int,label)
                XCTAssertEqual(policy.pendingTimers.ended.map { Int(($0*1000).rounded()) },timers["endedAtMs"] as? Int,label)
            }
            try send(["type":"meetings","meetings":[["tabId":tab,"title":"Changed URL","url":"https://wire.example/replacement","sourceCount":1,"heard":true,"pageState":"present"]]],to:&registry,peer:id)
            let request = try XCTUnwrap(registry.stop(.init(peer:id,tabID:tab),captureID:"reload-capture"),"The original recording must still receive Stop after navigation")
            let command = try XCTUnwrap(JSONSerialization.jsonObject(with:request.data) as? [String:Any])
            XCTAssertEqual(command["action"] as? String,"stop"); XCTAssertEqual(command["tabId"] as? Int,tab)
            try send(["type":"result","requestId":request.id,"ok":true],to:&registry,peer:id)
            XCTAssertFalse(registry.snapshots.first?.captures.contains { $0.captureID == "reload-capture" } ?? true)
        }
    }
    func testTabScopedEvidencePreservesOtherCapturesAndAcceptedResultIdentity() throws {
        for result in [false,true] {
            for recording in [false,true] {
                let id = UUID(); var state = BrowserControlRegistry()
                try state.connect(.init(id:id,role:.control,browser:"Fixture",browserInstance:.init(pid:4321,startSeconds:100)))
                try send(["type":"hello","version":1,"capabilities":["independent-sessions-v1","page-state-v1"]],to:&state,peer:id)
                try send(["type":"meetings","meetings":[2,7].map { ["tabId":$0,"title":"Call","url":"https://meet.example/original","sourceCount":1,"heard":true,"pageState":"present"] }],to:&state,peer:id)
                let sessions: [[String:Any]] = [2,7].map { ["tabId":$0,"captureId":"capture-\($0)","recording":true,"path":"/test/\($0)","tracks":3,"message":"","pageState":"present"] }
                try send(["type":"status","recording":true,"tabId":2,"path":"/test/2","message":"","sessions":sessions],to:&state,peer:id)
                let report: [String:Any] = ["type":"status","recording":recording,"tabId":2,"path":NSNull(),"message":"","pageState":"navigating"]
                if result {
                    let pending = try XCTUnwrap(state.stop(.init(peer:id,tabID:7),captureID:"capture-7",userInitiated:false))
                    try send(["type":"result","requestId":pending.id,"ok":false,"error":"Fixture failed command","status":report],to:&state,peer:id)
                } else { try send(report,to:&state,peer:id) }
                let snapshot = try XCTUnwrap(state.snapshots.first)
                XCTAssertEqual(Set(snapshot.captures.compactMap(\.captureID)),["capture-2","capture-7"])
                XCTAssertTrue(snapshot.captures.allSatisfy { $0.recording && $0.tracks == 3 && $0.path != nil })
                XCTAssertEqual(snapshot.captures.first { $0.key.tabID == 2 }?.pageState,.navigating)
                XCTAssertEqual(snapshot.meetings.first { $0.key.tabID == 2 }?.sourceCount,0)
                XCTAssertEqual(snapshot.meetings.first { $0.key.tabID == 7 }?.sourceCount,1)
            }
        }
    }
    func testExplicitSessionsRemainAuthoritativeEvenWithIDlessEntries() throws {
        let id = UUID(); var state = BrowserControlRegistry()
        try state.connect(.init(id:id,role:.control,browser:"Fixture"))
        try send(["type":"hello","version":1,"capabilities":["independent-sessions-v1","page-state-v1"]],to:&state,peer:id)
        let identified: [String:Any] = ["recording":true,"tabId":2,"captureId":"original","path":"/test/original","message":""]
        try send(["type":"status","recording":true,"tabId":2,"path":"/test/original","message":"","sessions":[identified]],to:&state,peer:id)
        var unknown = identified; unknown.removeValue(forKey:"captureId")
        try send(["type":"status","recording":true,"tabId":2,"path":"/test/new","message":"","sessions":[unknown]],to:&state,peer:id)
        XCTAssertEqual(state.snapshots.first?.captures.count,1); XCTAssertNil(state.snapshots.first?.captures.first?.captureID)
        var replacement = identified; replacement["captureId"] = "replacement"
        try send(["type":"status","recording":true,"tabId":2,"path":"/test/new","message":"","sessions":[replacement]],to:&state,peer:id)
        XCTAssertEqual(state.snapshots.first?.captures.first?.captureID,"replacement")
        XCTAssertNil(try state.stop(.init(peer:id,tabID:2),captureID:"original"),"An old Stop cannot target an explicit replacement")
        try send(["type":"status","recording":false,"tabId":NSNull(),"path":NSNull(),"message":"","sessions":[]],to:&state,peer:id)
        XCTAssertTrue(state.snapshots.first?.captures.isEmpty == true)
    }
    func testInactiveStatusAlsoInvalidatesOnlyItsOwnTab() throws {
        for sessions in [false,true] {
            let id = UUID(); var state = BrowserControlRegistry()
            try state.connect(.init(id:id,role:.control,browser:"Fixture"))
            try send(["type":"hello","version":1,"capabilities":["independent-sessions-v1","page-state-v1"]],to:&state,peer:id)
            try send(["type":"meetings","meetings":[2,3].map { ["tabId":$0,"title":"Call","url":"https://meet.example/call","sourceCount":3,"heard":true,"pageState":"present"] }],to:&state,peer:id)
            var packet: [String:Any] = ["type":"status","recording":false,"tabId":2,"path":NSNull(),"message":"","pageState":"closed"]
            if sessions { packet.removeValue(forKey:"pageState"); packet["sessions"] = [["recording":false,"tabId":2,"path":NSNull(),"message":"","pageState":"closed"]] }
            try send(packet,to:&state,peer:id)
            let meetings = try XCTUnwrap(state.snapshots.first?.meetings)
            XCTAssertEqual(meetings.first { $0.key.tabID == 2 }?.sourceCount,0)
            XCTAssertEqual(meetings.first { $0.key.tabID == 2 }?.heard,false)
            XCTAssertEqual(meetings.first { $0.key.tabID == 2 }?.pageState,.closed)
            XCTAssertEqual(meetings.first { $0.key.tabID == 3 }?.sourceCount,3)
            XCTAssertEqual(meetings.first { $0.key.tabID == 3 }?.heard,true)
        }
    }
    func testAStaleCommandResultCannotInvalidateANewerInventory() throws {
        let id = UUID(); var state = BrowserControlRegistry()
        try state.connect(.init(id:id,role:.control,browser:"Fixture"))
        try send(["type":"hello","version":1,"capabilities":["independent-sessions-v1","page-state-v1"]],to:&state,peer:id)
        try send(["type":"meetings","meetings":[["tabId":2,"title":"Call","url":"https://meet.example/call","sourceCount":3,"heard":true,"pageState":"present"]]],to:&state,peer:id)
        try send(["type":"status","recording":false,"tabId":NSNull(),"path":NSNull(),"message":""],to:&state,peer:id)
        let request = try state.start(.init(peer:id,tabID:2),microphone:false)
        let current: [String:Any] = ["type":"status","recording":true,"tabId":2,"path":"/test/recording","message":"","captureId":"current","pageState":"present"]
        try send(current,to:&state,peer:id)
        var obsolete = current; obsolete["pageState"] = "navigating"
        try send(["type":"result","requestId":request.id,"ok":true,"status":obsolete],to:&state,peer:id)
        let meeting = try XCTUnwrap(state.snapshots.first?.meetings.first)
        XCTAssertEqual(meeting.sourceCount,3); XCTAssertTrue(meeting.heard)
        XCTAssertEqual(meeting.pageState,.present)
    }
}
