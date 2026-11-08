// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
import CassiniKit
@testable import CassiniBrowserControl

private final class PassiveProofState: @unchecked Sendable {
    private let lock = NSLock()
    private var time: UInt64 = 1_000
    private var rows: [BrowserControlPeerSnapshot] = []
    private var nativeStarts = 0
    private var signalExpectation: XCTestExpectation?
    func expectSignalStart(_ value: XCTestExpectation) { lock.withLock { signalExpectation = value } }
    func signal(_ action: BrowserSignalAction) {
        if case .start = action {
            let done = lock.withLock { nativeStarts += 1; return signalExpectation }
            done?.fulfill()
        }
    }
    var signalStarts: Int { lock.withLock { nativeStarts } }
    func now() -> UInt64 { lock.withLock { time } }
    func advance() { lock.withLock { time += 10_000 } }
    func update(_ value: [BrowserControlPeerSnapshot]) { lock.withLock { rows = value } }
    var meeting: BrowserMeeting? { lock.withLock { rows.flatMap(\.meetings).first { $0.sourceCount > 0 } } }
}

final class PassiveWebRTCStartTests: XCTestCase {
    func testCapturedPassiveViewerCannotAutomaticallyStart() throws {
        let url = ProcessInfo.processInfo.environment["CASSINI_PASSIVE_COMPANION_OUTPUT"].map { URL(fileURLWithPath:$0) }
            ?? Bundle.module.url(forResource:"passive-webrtc-companion-0.2.25",withExtension:"json",subdirectory:"Fixtures")!
        let fixture = try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:url)) as? [String:Any])
        XCTAssertEqual(fixture["extensionVersion"] as? String,"0.2.25")
        let page = try XCTUnwrap(fixture["page"] as? [String:Any])
        XCTAssertEqual(page["microphoneRequests"] as? Int,0)
        let discovery = try XCTUnwrap(page["discovery"] as? [String:Any])
        XCTAssertEqual(discovery["callGeneration"] as? String,"0")
        let wire = try XCTUnwrap(fixture["wire"] as? [[String:Any]])
        XCTAssertFalse(wire.isEmpty)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CassiniPassiveConsumer-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        defer { try? FileManager.default.removeItem(at:root) }
        let state = PassiveProofState(), applied = expectation(description:"all companion status frames reconciled")
        applied.expectedFulfillmentCount = wire.filter { $0["type"] as? String == "status" }.count
        // This broker can never create a recording, open a device or run an audio
        // input. The real control service still emits its actual wire commands.
        let broker = BrowserAudioBroker(make:{ _,_ in XCTFail("No recording may be created"); throw BrowserIPCError.unavailable },
            created:{ _,_ in XCTFail("No audio capture may attach") },stopNative:{ _,reply in reply(nil) })
        let service = BrowserControlService(changed:{ state.update($0) },completed:{ _,_ in },audio:broker,
            canStart:{ true },clock:{ state.now() },received:{ if $0 == "status" { applied.fulfill() } },requireMultiStream:true,allowAutomaticBrowserStarts:false,signalAction:{ state.signal($0) })
        try service.start(root:root); defer { service.stop() }
        service.setAutoRecord(true,microphone:true)
        let client = try PipeEndpoint(root:root,role:.control,browser:"Chromium",browserInstance:BrowserInstance.process(getpid()))
        defer { client.stop() }
        for packet in wire { try client.send(JSONSerialization.data(withJSONObject:packet)) }
        wait(for:[applied],timeout:5)
        // A real heartbeat is an ordered output barrier. Nothing is inferred
        // from a quiet interval or a timeout: every Start before this ping is read.
        func drainThroughPing() throws -> [JSON] {
            state.advance(); service.tickHeartbeats()
            var commands: [JSON] = []
            for _ in 0..<64 {
                let data = try XCTUnwrap(client.receive(deadline:DispatchTime.now().uptimeNanoseconds+5_000_000_000))
                let value = try JSONParser.parse(data)
                if value["type"]?.string == "ping" { return commands }
                commands.append(value)
            }
            XCTFail("No heartbeat barrier"); return commands
        }
        let commands = try drainThroughPing()
        let starts = commands.filter { $0["action"]?.string == "start" }
        print("D80 guarded actual automatic Start commands: \(starts.count); audio captures: \(broker.activeCaptures.count)")
        XCTAssertTrue(starts.isEmpty,"A ready/heard passive viewer must not emit automatic Start")
        let row = try XCTUnwrap(state.meeting)
        XCTAssertNotEqual(row.callGeneration,"0","Companion maps hook generations to an opaque control identity")
        XCTAssertEqual(row.sourceCount,1); XCTAssertTrue(row.heard,"Source observation stays truthful")
        XCTAssertTrue(broker.activeCaptures.isEmpty)
        XCTAssertEqual(state.signalStarts,0)
        // Explicit Record remains source-based and emits only into this inert
        // peer. It is never forwarded to Chromium or an audio host.
        service.recordMeeting(row.key,microphone:false)
        let manual = try drainThroughPing().filter { $0["action"]?.string == "start" }
        XCTAssertEqual(manual.count,1)
        XCTAssertEqual(manual.first?["tabId"]?.int,row.key.tabID)
        XCTAssertEqual(manual.first?["microphone"]?.bool,false)
        XCTAssertEqual(manual.first?["callGeneration"]?.string,row.callGeneration)
        // Synthetic positive control for the independent D74 native-signal
        // route. Only its action callback is observed; no input factory runs.
        let signals = try XCTUnwrap(wire.last { $0["type"] as? String == "callSignals" })
        let profile = try XCTUnwrap(signals["browserInstance"] as? String)
        let sequence = try XCTUnwrap(signals["sequence"] as? Int)+1
        let mixed = expectation(description:"positive mixed-call native Start action")
        state.expectSignalStart(mixed)
        let positive: [String:Any] = ["type":"callSignals","browserInstance":profile,"sequence":sequence,"tabs":[[
            "tabId":row.key.tabID+1,"url":"https://generated.example/call","documentGeneration":"generated-document",
            "remoteAudio":"mixed","callEvidence":["state":"active","reason":"activeCall",
            "adapter":["name":"Generated call evidence","version":"1"],"callGeneration":"generated-mixed-call"]]]]
        try client.send(JSONSerialization.data(withJSONObject:positive))
        wait(for:[mixed],timeout:5)
        XCTAssertFalse(try drainThroughPing().contains { $0["action"]?.string == "start" },"Mixed calls never send browser Start")
        XCTAssertEqual(state.signalStarts,1)
        XCTAssertTrue(broker.activeCaptures.isEmpty)
        print("D80 explicit browser Start commands: \(manual.count); positive mixed native actions: \(state.signalStarts); actual captures: \(broker.activeCaptures.count)")
    }

    func testAutomaticStartCannotBypassBoundaryGuard() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource:"passive-webrtc-companion-0.2.25",withExtension:"json",subdirectory:"Fixtures"))
        let fixture = try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:url)) as? [String:Any])
        let wire = try XCTUnwrap(fixture["wire"] as? [[String:Any]])
        let id = UUID()
        var state = BrowserControlRegistry()
        state.requireMultiStream = true; state.allowAutomaticBrowserStarts = false
        try state.connect(.init(id:id,role:.control,browser:"Chromium"))
        for packet in wire { try state.receive(JSONSerialization.data(withJSONObject:packet),from:id) }
        let row = try XCTUnwrap(state.snapshots.first?.meetings.first { $0.sourceCount > 0 && $0.heard })
        XCTAssertTrue(state.automaticStarts(microphone:true).isEmpty)
        XCTAssertThrowsError(try state.start(row.key,microphone:true,automatic:true))
        XCTAssertNoThrow(try state.start(row.key,microphone:false),"Explicit Record is preserved")
    }
}
