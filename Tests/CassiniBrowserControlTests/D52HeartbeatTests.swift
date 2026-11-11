// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
import Foundation
import CassiniKit
@testable import CassiniBrowserControl

private final class TestClock: @unchecked Sendable {
    private let lock = NSLock(); private var value: UInt64 = 1_000_000
    func now() -> UInt64 { lock.withLock { value } }
    func advance(_ ms: UInt64) { lock.withLock { value += ms } }
}

private struct Fed: Equatable { let id: String; let page: BrowserCallLifecycle.Page?; let document: String? }
private final class DocumentRecorder: BrowserAudioHandler, @unchecked Sendable {
    private let lock = NSLock(); private var fed: [Fed] = []; private var remaining = 0
    var done: XCTestExpectation?
    var calls: [Fed] { lock.withLock { fed } }
    func expect(_ count: Int, _ test: XCTestCase) { lock.withLock { remaining = count; done = test.expectation(description:"documents fed") } }
    var retainedCaptureIDs: [String] { [] }
    func connected(_ connection: BrowserPipeConnection) { connection.close() }
    func received(_ data: Data, from connection: BrowserPipeConnection) {}
    func disconnected(_ peer: BrowserPeer) {}
    func documentChanged(captureID: String, page: BrowserCallLifecycle.Page?, documentGeneration: String?) {
        let finished: XCTestExpectation? = lock.withLock {
            fed.append(.init(id:captureID,page:page,document:documentGeneration)); remaining -= 1
            return remaining == 0 ? done : nil
        }
        finished?.fulfill()
    }
}

/// D52.4 R72 / P11 heartbeat-v1: the shared timing vectors through the Mac
/// heartbeat, and a ping/pong over the real control pipes.
final class D52HeartbeatTests: XCTestCase {
    func testSharedHeartbeatVectors() throws {
        let url = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("browser-protocol/conformance/control/heartbeat-vectors.json")
        let file = try JSONParser.parse(Data(contentsOf:url))
        XCTAssertEqual(file["constants"]?["HEARTBEAT_INTERVAL"]?.int,Int(ControlHeartbeat.interval))
        XCTAssertEqual(file["constants"]?["CONTROL_LOSS_AFTER"]?.int,Int(ControlHeartbeat.lossAfter))
        let cases = try XCTUnwrap(file["cases"]?.array)
        XCTAssertEqual(cases.count,10)
        for vector in cases {
            let name = try XCTUnwrap(vector["name"]?.string)
            var heartbeat: ControlHeartbeat?
            for step in try XCTUnwrap(vector["steps"]?.array) {
                let at = UInt64(try XCTUnwrap(step["atMs"]?.int))
                switch step["in"]?.string {
                case "hello"?:
                    // A hello is a fresh connection, as on Mac: a new peer and a new heartbeat.
                    var fresh = ControlHeartbeat(); fresh.hello(capabilities:step["capabilities"]?.array?.compactMap(\.string) ?? [],at:at); heartbeat = fresh
                case let type?: heartbeat?.inbound(type,at:at)
                case nil: break
                }
                let actual: [String]
                switch heartbeat?.tick(at:at) {
                case .ping(let sequence)?: actual = ["ping:\(sequence)"]
                case .lost?: actual = ["controlLost"]; heartbeat = nil
                case nil: actual = []
                }
                XCTAssertEqual(actual,step["expect"]?.array?.compactMap(\.string),"\(name) at \(at)")
            }
        }
    }

    private func temporary() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("CassiniHeartbeat-" + UUID().uuidString)
        try FileManager.default.createDirectory(at:url,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        return url
    }
    private func send(_ value: [String:Any], _ client: PipeEndpoint) throws { try client.send(JSONSerialization.data(withJSONObject:value)) }
    private func receive(_ client: PipeEndpoint, seconds: Double = 3) throws -> JSON {
        guard let data = try client.receive(deadline:DispatchTime.now().uptimeNanoseconds + UInt64(seconds*1_000_000_000)) else { throw BrowserIPCError.closed }
        return try JSONParser.parse(data)
    }
    private func connect(_ root: URL, capabilities: [String]) throws -> PipeEndpoint {
        let client = try PipeEndpoint(root:root,role:.control,browser:"Chrome",browserInstance:BrowserInstance.process(getpid()))
        try send(["type":"hello","version":1,"capabilities":capabilities],client)
        try send(["type":"meetings","meetings":[]],client)
        try send(["type":"status","recording":false,"tabId":NSNull(),"path":NSNull(),"message":"Status","sessions":[]],client)
        return client
    }

    func testPingsOverTheRealPipeAndSilenceLosesControl() throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at:root) }
        let clock = TestClock()
        let connected = expectation(description:"status received"), gone = expectation(description:"control lost")
        connected.assertForOverFulfill = false; gone.assertForOverFulfill = false
        let pong = expectation(description:"pong received")
        let service = BrowserControlService(changed:{ peers in
            if peers.contains(where:{ $0.reconciled }) { connected.fulfill() } else if peers.isEmpty { gone.fulfill() }
        },completed:{ _,_ in },clock:clock.now,received:{ if $0 == "pong" { pong.fulfill() } })
        try service.start(root:root); defer { service.stop() }
        let client = try connect(root,capabilities:["multi-stream-v1","heartbeat-v1"])
        wait(for:[connected],timeout:3)
        clock.advance(9_999); service.tickHeartbeats()
        clock.advance(1); service.tickHeartbeats()
        let ping = try receive(client)
        XCTAssertEqual(ping["type"]?.string,"ping"); XCTAssertEqual(ping["seq"]?.int,0)
        try send(["type":"pong","seq":0],client)
        // Wait until the service has taken the pong, so the clock never moves under it.
        wait(for:[pong],timeout:3)
        XCTAssertEqual(service.lastHeartbeatInbound(),clock.now())
        clock.advance(10_000); service.tickHeartbeats()
        XCTAssertEqual(try receive(client)["seq"]?.int,1)
        // Nothing more from the extension: control is lost exactly 25 s after the pong.
        clock.advance(14_999); service.tickHeartbeats()
        XCTAssertNotNil(service.lastHeartbeatInbound(),"still connected 1 ms before the deadline")
        XCTAssertEqual(try receive(client)["seq"]?.int,2,"pings are unconditional, not idle-only")
        clock.advance(1); service.tickHeartbeats()
        wait(for:[gone],timeout:3)
        XCTAssertNil(try client.receive(deadline:DispatchTime.now().uptimeNanoseconds + 3_000_000_000),"The lost connection must close; a receive timeout fails")
    }

    /// D57: every status confirms each session's document to the audio side as it arrives.
    func testEachStatusFeedsItsSessionsDocumentToTheAudioWatchdog() throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at:root) }
        let audio = DocumentRecorder(), connected = expectation(description:"status received")
        connected.assertForOverFulfill = false
        let service = BrowserControlService(changed:{ peers in if peers.contains(where:{ $0.reconciled }) { connected.fulfill() } },
                                            completed:{ _,_ in },audio:audio)
        try service.start(root:root); defer { service.stop() }
        let client = try connect(root,capabilities:["independent-sessions-v1","page-state-v1","multi-stream-v1"])
        wait(for:[connected],timeout:3)
        let session: [String:Any] = ["recording":true,"tabId":2,"captureId":"cap-1","path":NSNull(),"message":"Recording","tracks":1,
                                     "pageState":"navigating","documentGeneration":"doc-1"]
        let status: [String:Any] = ["type":"status","recording":true,"tabId":2,"path":NSNull(),"message":"Recording","sessions":[session]]
        audio.expect(2,self)
        try send(status,client); try send(status,client)
        wait(for:[audio.done!],timeout:3)
        XCTAssertEqual(audio.calls,[Fed(id:"cap-1",page:.navigating,document:"doc-1"),Fed(id:"cap-1",page:.navigating,document:"doc-1")])
    }

    func testALegacyHelloIsNeverPingedOrTimedOut() throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at:root) }
        let clock = TestClock(), frames = SignalFrameWaiter(), connected = expectation(description:"status received")
        connected.assertForOverFulfill = false
        let service = BrowserControlService(changed:{ peers in if peers.contains(where:{ $0.reconciled }) { connected.fulfill() } },
                                            completed:{ _,_ in },clock:clock.now,received:{ frames.received($0) })
        try service.start(root:root); defer { service.stop() }
        let client = try connect(root,capabilities:["multi-stream-v1","resume-capture-v1"])
        wait(for:[connected],timeout:3)
        for _ in 0..<30 { clock.advance(10_000); service.tickHeartbeats() }
        let inbound = service.lastHeartbeatInbound()
        XCTAssertNotNil(inbound,"A legacy hello must not time out")
        guard inbound != nil else { return } // A removed peer must fail before waiting on an impossible reply.
        // An ordinary inventory must still be accepted after 300 virtual seconds.
        // The requested legacy Stop then fences all earlier output on this peer.
        let inventory = expectation(description:"Legacy inventory accepted after heartbeat advances")
        frames.expect("meetings",inventory)
        try send(["type":"meetings","meetings":[]],client)
        wait(for:[inventory],timeout:3)
        clock.advance(ControlHeartbeat.interval); service.tickHeartbeats()
        let recording = expectation(description:"Legacy recording status applied")
        frames.expect("status",recording)
        try send(["type":"status","recording":true,"tabId":2,"path":NSNull(),"message":"Recording",
                  "sessions":[["tabId":2,"captureId":"legacy","recording":true,"path":NSNull(),"message":"Recording"]]],client)
        wait(for:[recording],timeout:3)
        clock.advance(ControlHeartbeat.interval); service.tickHeartbeats()
        service.stopRecordings()
        let command = try receive(client)
        XCTAssertEqual(command["type"]?.string,"command","A legacy peer must receive no heartbeat before the requested command")
        XCTAssertEqual(command["action"]?.string,"stop")
        XCTAssertEqual(command["tabId"]?.int,2)
    }
}
