// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
import CassiniKit
@testable import CassiniBrowserControl

final class BrowserCompanionHealthTests: XCTestCase {
    let peer = UUID()
    func send(_ value: [String:Any], _ state: inout BrowserControlRegistry, peer: UUID? = nil) throws {
        try state.receive(JSONSerialization.data(withJSONObject:value),from:peer ?? self.peer)
    }
    func health(_ mode: String = "reloadRequired", tab: Int = 2) -> [String:Any] {
        ["state":mode,"nativeControl":"connected","worker":"ready","extensionVersion":"0.2.20","extensionInstance":"instance","filesOk":true,
         "tabs":[["tabId":tab,"state":"reloadRequired","hookSeen":true,"relayAlive":false,"message":"Reload the meeting tab so Cassini can record it.","action":"reloadMeetingTab"]]]
    }
    func status(_ health: Any? = nil) -> [String:Any] {
        var value: [String:Any] = ["type":"status","recording":false,"tabId":NSNull(),"path":NSNull(),"message":"Ready","sessions":[]]
        value["browserHealth"] = health; return value
    }
    func connect(_ state: inout BrowserControlRegistry, peer: UUID? = nil, files: Any? = true, readiness: Bool = true) throws {
        let id = peer ?? self.peer
        try state.connect(.init(id:id,role:.control,browser:"Chrome"))
        var hello: [String:Any] = ["type":"hello","version":1,"capabilities":["independent-sessions-v1","multi-stream-v1"] + (readiness ? ["tab-readiness-v1"] : []),"extensionVersion":"0.2.20","extensionInstance":"instance"]
        hello["filesOk"] = files
        try send(hello,&state,peer:id)
        try send(["type":"meetings","meetings":[["tabId":2,"title":"Synthetic English call","url":"https://meet.example/call","sourceCount":1]]],&state,peer:id)
        try send(status(),&state,peer:id)
    }
    func testPinnedConsumerReadinessAndHelloVectors() throws {
        let root = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("browser-protocol/conformance/control")
        let readiness = try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:root.appendingPathComponent("tab-readiness-vectors.json"))) as? [[String:Any]])
        for vector in readiness {
            var state = BrowserControlRegistry(); try connect(&state)
            try send(try XCTUnwrap(vector["status"] as? [String:Any]),&state)
            XCTAssertEqual(!BrowserCompanionSetupHealth(peers:state.snapshots).reloadTabs.isEmpty,vector["expectReloadWarning"] as? Bool,vector["name"] as? String ?? "vector")
        }
        let diagnostics = try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:root.appendingPathComponent("companion-diagnostics-vectors.json"))) as? [String:Any])
        for vector in try XCTUnwrap(diagnostics["hellos"] as? [[String:Any]]) {
            var state = BrowserControlRegistry(); try state.connect(.init(id:peer,role:.control,browser:"Chrome"))
            let hello = try XCTUnwrap(vector["hello"] as? [String:Any])
            try send(hello,&state); try send(status(),&state)
            let snapshot = try XCTUnwrap(state.snapshots.first)
            XCTAssertEqual(snapshot.diagnostics.filesOk,hello["filesOk"] as? Bool)
            XCTAssertEqual(snapshot.diagnostics.extensionVersion,hello["extensionVersion"] as? String)
            XCTAssertEqual(snapshot.diagnostics.installType,hello["installType"] as? String)
            XCTAssertEqual(snapshot.setupComplete,hello["filesOk"] as? Bool == true)
        }
    }
    func testSetupRequiresReconciledConnectionAndExplicitFileCheckForEveryProfile() throws {
        var state = BrowserControlRegistry()
        XCTAssertFalse(BrowserCompanionSetupHealth(peers:state.snapshots).complete)
        try connect(&state)
        XCTAssertTrue(BrowserCompanionSetupHealth(peers:state.snapshots).complete)
        let other = UUID(); try connect(&state,peer:other,files:nil)
        XCTAssertFalse(BrowserCompanionSetupHealth(peers:state.snapshots).complete)
        try send(status(health()),&state,peer:other)
        XCTAssertTrue(BrowserCompanionSetupHealth(peers:state.snapshots).complete)
        var broken = health(); broken["filesOk"] = false
        try send(status(broken),&state)
        XCTAssertFalse(BrowserCompanionSetupHealth(peers:state.snapshots).complete)
        XCTAssertNoThrow(try state.start(.init(peer:peer,tabID:2),microphone:false),"Diagnostics do not gate Start")
        state.disconnect(peer); state.disconnect(other)
        XCTAssertFalse(BrowserCompanionSetupHealth(peers:state.snapshots).complete)
    }
    func testUnknownAndMalformedDiagnosticsRemainOptionalAndAnInstanceChangeClearsOldChecks() throws {
        var d = BrowserCompanionDiagnostics()
        d.update(try JSONParser.parse(Data(#"{"extensionVersion":"0.2.9","extensionInstance":"old","filesOk":true,"installType":"development"}"#.utf8)))
        XCTAssertTrue(d.isOlder(than:"0.2.20")); XCTAssertFalse(d.isOlder(than:"0.2.9.0"))
        d.update(try JSONParser.parse(Data(#"{"state":"idle"}"#.utf8))); XCTAssertEqual(d.filesOk,true)
        d.update(try JSONParser.parse(Data(#"{"extensionInstance":"new"}"#.utf8)))
        XCTAssertNil(d.filesOk); XCTAssertNil(d.extensionVersion)
        d.update(try JSONParser.parse(Data(#"{"extensionVersion":"9999999999999999999999999999.2","filesOk":1,"installType":"bad\ntext"}"#.utf8)))
        XCTAssertNil(d.filesOk); XCTAssertNil(d.installType); XCTAssertFalse(d.isOlder(than:"0.2.20"))
        for files: Any in [NSNull(),1,"true"] {
            var state = BrowserControlRegistry(); try connect(&state,files:files)
            XCTAssertFalse(BrowserCompanionSetupHealth(peers:state.snapshots).complete)
            XCTAssertNoThrow(try state.start(.init(peer:peer,tabID:2),microphone:true))
        }
    }
    func testReloadIsExplicitNamespacedAndDoesNotRequireDiscoverableMeetingOrInferIdleFailure() throws {
        var state = BrowserControlRegistry(); try connect(&state)
        let other = UUID(); try connect(&state,peer:other)
        // A stale injected page may be missing from the ready meetings inventory.
        try send(status(health(tab:9)),&state)
        try send(status(health(tab:9)),&state,peer:other)
        XCTAssertEqual(Set(BrowserCompanionSetupHealth(peers:state.snapshots).reloadTabs.map(\.key)),Set([.init(peer:peer,tabID:9),.init(peer:other,tabID:9)]))
        let request = try state.reloadTab(.init(peer:peer,tabID:9))
        let wire = try JSONParser.parse(request.data)
        XCTAssertEqual(Set(try XCTUnwrap(wire.object).map { $0.0 }),Set(["type","requestId","action","tabId"]))
        XCTAssertEqual(wire["action"]?.string,"reloadTab"); XCTAssertEqual(wire["tabId"]?.int,9)
        XCTAssertThrowsError(try state.reloadTab(request.key))
        XCTAssertNoThrow(try state.reloadTab(.init(peer:other,tabID:9)))
        try send(status(health("idle",tab:9)),&state)
        XCTAssertTrue(state.snapshots.first(where:{ $0.id == peer })?.browserHealth?.reloadTabs.isEmpty == true)
        XCTAssertThrowsError(try state.reloadTab(.init(peer:peer,tabID:2)))
    }
    func testStaleReloadResultCannotReviveNewerHealthOrSelfCheck() throws {
        var state = BrowserControlRegistry(); try connect(&state); try send(status(health()),&state)
        let request = try state.reloadTab(.init(peer:peer,tabID:2))
        var fresh = health("ready"); fresh["tabs"] = []; fresh["filesOk"] = false
        try send(status(fresh),&state)
        let revision = try XCTUnwrap(state.snapshots.first?.healthRevision)
        try send(["type":"result","requestId":request.id,"ok":true,"status":status(health())],&state)
        XCTAssertEqual(state.snapshots.first?.healthRevision,revision)
        XCTAssertEqual(state.snapshots.first?.diagnostics.filesOk,false)
        XCTAssertEqual(state.snapshots.first?.browserHealth?.state,.ready)
        XCTAssertTrue(state.outcomes.last?.ok == true)
        XCTAssertEqual(state.automaticStarts(microphone:false).map(\.key.tabID),[2],"Repair must not consume a Record attempt")
    }
    func testFreshResultUpdatesHealthButAbsentAndInvalidHealthClearOldReloadAdvice() throws {
        var state = BrowserControlRegistry(); try connect(&state); try send(status(health()),&state)
        let request = try state.reloadTab(.init(peer:peer,tabID:2))
        var ready = health("ready"); ready["tabs"] = []
        try send(["type":"result","requestId":request.id,"ok":true,"status":status(ready)],&state)
        XCTAssertEqual(state.snapshots.first?.browserHealth?.state,.ready)
        for raw: Any? in [nil,["state":"future","tabs":[]], ["state":"reloadRequired","tabs":[["tabId":true,"state":"reloadRequired"]]]] {
            try send(status(health()),&state); try send(status(raw),&state)
            XCTAssertNil(state.snapshots.first?.browserHealth)
            XCTAssertEqual(state.snapshots.first?.diagnostics.filesOk,true,"Absent health preserves hello diagnostics")
        }
    }
    func testHealthBoundsAndCapabilityAndCaptureGuards() throws {
        for id: Any in [-1,true,1.5,9_007_199_254_740_992] {
            var h = health(); h["tabs"] = [["tabId":id,"state":"reloadRequired"]]
            XCTAssertNil(BrowserCompanionHealth.read(try JSONParser.parse(JSONSerialization.data(withJSONObject:h)),peer:peer))
        }
        var h = health(); h["tabs"] = Array(repeating:["tabId":2,"state":"ready"],count:2)
        XCTAssertNil(BrowserCompanionHealth.read(try JSONParser.parse(JSONSerialization.data(withJSONObject:h)),peer:peer))
        var state = BrowserControlRegistry(); try connect(&state,readiness:false); try send(status(health()),&state)
        XCTAssertThrowsError(try state.reloadTab(.init(peer:peer,tabID:2)))
        var capable = BrowserControlRegistry(); try connect(&capable); try send(status(health()),&capable)
        var live = status(health()); live["recording"] = true; live["tabId"] = 2
        live["sessions"] = [["recording":true,"tabId":2,"captureId":"live","path":NSNull(),"message":"Recording"]]
        try send(live,&capable)
        XCTAssertThrowsError(try capable.reloadTab(.init(peer:peer,tabID:2)))
    }
}
