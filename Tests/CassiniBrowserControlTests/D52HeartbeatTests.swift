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
        let service = BrowserControlService(changed:{ peers in
            if peers.contains(where:{ $0.reconciled }) { connected.fulfill() } else if peers.isEmpty { gone.fulfill() }
        },completed:{ _,_ in },clock:clock.now)
        try service.start(root:root); defer { service.stop() }
        let client = try connect(root,capabilities:["multi-stream-v1","heartbeat-v1"])
        wait(for:[connected],timeout:3)
        clock.advance(9_999); service.tickHeartbeats()
        clock.advance(1); service.tickHeartbeats()
        let ping = try receive(client)
        XCTAssertEqual(ping["type"]?.string,"ping"); XCTAssertEqual(ping["seq"]?.int,0)
        try send(["type":"pong","seq":0],client)
        // Wait until the service has taken the pong, so the clock never moves under it.
        let deadline = Date().addingTimeInterval(3)
        while service.lastHeartbeatInbound() != clock.now() {
            guard Date() < deadline else { return XCTFail("the pong was never received") }
            Thread.sleep(forTimeInterval:0.005)
        }
        clock.advance(10_000); service.tickHeartbeats()
        XCTAssertEqual(try receive(client)["seq"]?.int,1)
        // Nothing more from the extension: control is lost exactly 25 s after the pong.
        clock.advance(14_999); service.tickHeartbeats()
        XCTAssertNotNil(service.lastHeartbeatInbound(),"still connected 1 ms before the deadline")
        XCTAssertEqual(try receive(client)["seq"]?.int,2,"pings are unconditional, not idle-only")
        clock.advance(1); service.tickHeartbeats()
        wait(for:[gone],timeout:3)
        XCTAssertThrowsError(try receive(client,seconds:1),"the app closed the lost control connection")
    }

    func testALegacyHelloIsNeverPingedOrTimedOut() throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at:root) }
        let clock = TestClock(), connected = expectation(description:"status received")
        connected.assertForOverFulfill = false
        let service = BrowserControlService(changed:{ peers in if peers.contains(where:{ $0.reconciled }) { connected.fulfill() } },
                                            completed:{ _,_ in },clock:clock.now)
        try service.start(root:root); defer { service.stop() }
        let client = try connect(root,capabilities:["multi-stream-v1","resume-capture-v1"])
        wait(for:[connected],timeout:3)
        for _ in 0..<30 { clock.advance(10_000); service.tickHeartbeats() }
        XCTAssertThrowsError(try receive(client,seconds:0.3),"no ping to a legacy hello")
        // Still connected: an ordinary frame is accepted and nothing was closed.
        try send(["type":"meetings","meetings":[]],client)
        XCTAssertThrowsError(try receive(client,seconds:0.3))
    }
}
