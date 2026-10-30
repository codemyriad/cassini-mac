// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
import Foundation
import Darwin
import CassiniKit
@testable import CassiniBrowserControl

private final class NotificationCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}
private final class Admission: @unchecked Sendable {
    private let lock = NSLock()
    private var allowed = false
    func set(_ value: Bool) { lock.withLock { allowed = value } }
    func read() -> Bool { lock.withLock { allowed } }
}
final class ControlServiceTests: XCTestCase {
    func testFreshStopWithAStaleUIKeyUsesTheCurrentCaptureConnection() throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at:root) }
        let oldReady = expectation(description:"Old capture status"), newReady = expectation(description:"Replacement capture status")
        oldReady.assertForOverFulfill = false; newReady.assertForOverFulfill = false
        let instance = try XCTUnwrap(BrowserInstance.process(getpid()))
        // Observe the first peer UUID from its actual published local metadata.
        let service = BrowserControlService(changed:{ peers in
            guard let peer = peers.first, peer.captures.first?.captureID == "capture" else { return }
            if peer.captures.first?.path == "/replacement-status" { newReady.fulfill() }
            else { oldReady.fulfill() }
        },completed:{ _,_ in })
        try service.start(root:root); defer { service.stop() }
        let first = try PipeEndpoint(root:root,role:.control,browser:"Chrome",browserInstance:instance)
        let folder = try XCTUnwrap(FileManager.default.contentsOfDirectory(at:root.appendingPathComponent("clients"),includingPropertiesForKeys:nil).first { UUID(uuidString:$0.lastPathComponent) != nil })
        let oldKey = BrowserMeetingKey(peer:try XCTUnwrap(UUID(uuidString:folder.lastPathComponent)),tabID:2)
        try hello(first); try send(status(true),first)
        wait(for:[oldReady],timeout:3)
        let second = try PipeEndpoint(root:root,role:.control,browser:"Chrome",browserInstance:instance)
        try hello(second)
        var replacement = status(true)
        var sessions = replacement["sessions"] as! [[String:Any]]
        sessions[0]["path"] = "/replacement-status"; replacement["sessions"] = sessions
        try send(replacement,second)
        wait(for:[newReady],timeout:3)
        service.stopMeeting(oldKey,captureID:"capture")
        XCTAssertEqual(try receive(second)["action"]?.string,"stop")
        XCTAssertThrowsError(try receive(first,seconds:0.2))
    }
    func testDisconnectedCaptureStopSurvivesARealPipeReconnectAndNewURLCanStart() throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at:root) }
        let bound = expectation(description:"First status binds before audio registration")
        let gone = expectation(description:"Control connection gone")
        bound.assertForOverFulfill = false; gone.assertForOverFulfill = false
        let service = BrowserControlService(changed:{ peers in
            if peers.contains(where:{ $0.captures.first?.captureID == "capture" }) { bound.fulfill() }
            if peers.isEmpty { gone.fulfill() }
        },completed:{ _,_ in })
        try service.start(root:root); defer { service.stop() }
        let instance = try XCTUnwrap(BrowserInstance.process(getpid()))
        var first: PipeEndpoint? = try PipeEndpoint(root:root,role:.control,browser:"Chrome",browserInstance:instance)
        try hello(try XCTUnwrap(first)); try send(status(true),try XCTUnwrap(first))
        wait(for:[bound],timeout:3)
        first = nil
        wait(for:[gone],timeout:3)
        service.rememberUserStop(captureID:"capture",key:nil)
        service.setAutoRecord(true,microphone:false)
        let second = try PipeEndpoint(root:root,role:.control,browser:"Chrome",browserInstance:instance)
        try hello(second); try send(status(false),second)
        XCTAssertThrowsError(try receive(second,seconds:0.3))
        try send(["type":"meetings","meetings":[["tabId":2,"title":"New call","url":"https://meet.example/new","sourceCount":2]]],second)
        XCTAssertEqual(try receive(second)["action"]?.string,"start")
    }
    func testBlockedDestinationIssuesNoManualOrAutomaticStartAndCanRecover() throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at:root) }
        let admission = Admission()
        let service = BrowserControlService(changed:{ _ in },completed:{ _,_ in },canStart:{ admission.read() })
        try service.start(root:root); defer { service.stop() }
        service.setAutoRecord(true,microphone:true)
        let client = try PipeEndpoint(root:root,role:.control,browser:"Chrome")
        try hello(client); try send(status(false),client)
        XCTAssertThrowsError(try receive(client,seconds:0.2))
        let issued = expectation(description:"Blocked manual start returns no requests")
        service.recordAll(microphone:true) { requests in XCTAssertTrue(requests.isEmpty); issued.fulfill() }
        wait(for:[issued],timeout:2)
        XCTAssertThrowsError(try receive(client,seconds:0.2))
        admission.set(true)
        service.setAutoRecord(true,microphone:true)
        XCTAssertEqual(try receive(client)["action"]?.string,"start")
    }
    func temporary() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("CassiniServiceTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at:url,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        return url
    }
    func send(_ value: [String:Any], _ client: PipeEndpoint) throws { try client.send(JSONSerialization.data(withJSONObject:value)) }
    func hello(_ client: PipeEndpoint) throws {
        try send(["type":"hello","version":1,"capabilities":["independent-sessions-v1"]],client)
        try send(["type":"meetings","meetings":[["tabId":2,"title":"Call","url":"https://meet.example/call","sourceCount":2]]],client)
    }
    func status(_ recording: Bool) -> [String:Any] {
        ["type":"status","recording":recording,"tabId":recording ? 2 : NSNull(),"path":NSNull(),"message":"Status",
         "sessions":recording ? [["tabId":2,"captureId":"capture","recording":true,"path":NSNull(),"message":"Recording"]] : []]
    }
    func receive(_ client: PipeEndpoint, seconds: Double = 3) throws -> JSON {
        guard let data = try client.receive(deadline:DispatchTime.now().uptimeNanoseconds + UInt64(seconds*1_000_000_000)) else { throw BrowserIPCError.closed }
        return try JSONParser.parse(data)
    }
    func testAutomaticStartIsNotAnnouncedUntilItsAcknowledgementAndStopDoesNotRestart() throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at:root) }
        let announced = expectation(description:"auto start acknowledged"), notifications = NotificationCount()
        let service = BrowserControlService(changed:{ _ in },completed:{ result,automatic in
            if result.ok && result.action == .start && automatic { notifications.increment(); announced.fulfill() }
        })
        try service.start(root:root); defer { service.stop() }
        service.setAutoRecord(true,microphone:false)
        let client = try PipeEndpoint(root:root,role:.control,browser:"Chrome")
        try hello(client); try send(status(false),client)
        let start = try receive(client)
        XCTAssertEqual(start["action"]?.string,"start"); XCTAssertEqual(start["captureLocal"]?.bool,false)
        XCTAssertEqual(start["microphone"]?.bool,false); XCTAssertEqual(notifications.value,0)
        try send(["type":"result","requestId":try XCTUnwrap(start["requestId"]?.string),"ok":true,"status":status(true)],client)
        wait(for:[announced],timeout:3)
        service.stopRecordings()
        let stop = try receive(client); XCTAssertEqual(stop["action"]?.string,"stop"); XCTAssertEqual(stop["tabId"]?.int,2)
        try send(["type":"result","requestId":try XCTUnwrap(stop["requestId"]?.string),"ok":true,"status":status(false)],client)
        try send(status(false),client)
        XCTAssertThrowsError(try receive(client,seconds:0.2))
        XCTAssertEqual(notifications.value,1)
    }
    func testProfilesWithSameTabStaySeparateAndWaitForTheirOwnFirstStatus() throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at:root) }
        let service = BrowserControlService(changed:{ _ in },completed:{ _,_ in })
        try service.start(root:root); defer { service.stop() }
        service.setAutoRecord(true,microphone:true)
        let existing = try PipeEndpoint(root:root,role:.control,browser:"Chrome")
        try hello(existing); try send(status(true),existing)
        let fresh = try PipeEndpoint(root:root,role:.control,browser:"Chrome")
        try hello(fresh)
        XCTAssertThrowsError(try receive(fresh,seconds:0.2))
        try send(status(false),fresh)
        XCTAssertEqual(try receive(fresh)["action"]?.string,"start")
        XCTAssertThrowsError(try receive(existing,seconds:0.2))
    }
    func testMalformedPeerDisconnectDoesNotDisableAHealthyProfile() throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at:root) }
        let service = BrowserControlService(changed:{ _ in },completed:{ _,_ in })
        try service.start(root:root); defer { service.stop() }
        let bad = try PipeEndpoint(root:root,role:.control,browser:"Chrome")
        let healthy = try PipeEndpoint(root:root,role:.control,browser:"Chrome")
        try hello(bad); try hello(healthy); try send(status(false),healthy)
        var malformed = status(false); malformed["sessions"] = false
        try send(malformed,bad)
        XCTAssertNil(try bad.receive(deadline:DispatchTime.now().uptimeNanoseconds + 3_000_000_000))
        service.recordAll(microphone:true)
        XCTAssertEqual(try receive(healthy)["action"]?.string,"start")
    }
}
