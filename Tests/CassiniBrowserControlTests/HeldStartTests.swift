// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
import Foundation
import Darwin
import CassiniKit
@testable import CassiniBrowserControl

private final class HeldClock: @unchecked Sendable {
    private let lock = NSLock()
    private var instant: TimeInterval = 1000
    private var alive = true
    var now: TimeInterval { lock.withLock { instant } }
    var instanceAlive: Bool { lock.withLock { alive } }
    func advance(_ seconds: TimeInterval) { lock.withLock { instant += seconds } }
    func exit() { lock.withLock { alive = false } }
}
private final class Armed: @unchecked Sendable {
    private let lock = NSLock()
    private var expectation: XCTestExpectation?
    func arm(_ value: XCTestExpectation) { lock.withLock { expectation = value } }
    func fulfill() { lock.withLock { expectation }?.fulfill() }
}
private final class Completions: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [(BrowserControlOutcome,Bool)] = []
    func append(_ outcome: BrowserControlOutcome, _ automatic: Bool) { lock.withLock { values.append((outcome,automatic)) } }
    var all: [(BrowserControlOutcome,Bool)] { lock.withLock { values } }
}

/// A Start whose acknowledgement is lost with its control link (an extension worker restart)
/// may be recording. It settles ok once a newer link of the same browser reports that capture
/// for the same tab and call generation, instead of failing as disconnected while it runs.
final class HeldStartTests: XCTestCase {
    private let instance = BrowserInstance(pid:4242,startSeconds:1_793_000_000)
    private func send(_ value: [String:Any], _ state: inout BrowserControlRegistry, _ peer: UUID) throws {
        try state.receive(JSONSerialization.data(withJSONObject:value),from:peer)
    }
    private func meetings(_ generation: String) -> [String:Any] {
        ["type":"meetings","meetings":[["tabId":2,"title":"Call","url":"https://meet.example/2","sourceCount":1,"callGeneration":generation]]]
    }
    private func status(capture: String? = nil, generation: String = "call-A") -> [String:Any] {
        ["type":"status","recording":capture != nil,"tabId":capture == nil ? NSNull() : 2,"path":NSNull(),"message":"Status",
         "sessions":capture.map { [["tabId":2,"captureId":$0,"recording":true,"path":NSNull(),"message":"Recording","callGeneration":generation]] } ?? []]
    }
    private func ready(_ state: inout BrowserControlRegistry, instance: BrowserInstance? = nil, multiStream: Bool = true,
                       generation: String = "call-A", capture: String? = nil) throws -> UUID {
        let peer = UUID()
        try state.connect(.init(id:peer,role:.control,browser:"Chrome",browserInstance:instance ?? self.instance))
        let capabilities = multiStream ? ["independent-sessions-v1","multi-stream-v1"] : ["independent-sessions-v1"]
        try send(["type":"hello","version":1,"capabilities":capabilities],&state,peer)
        try send(meetings(generation),&state,peer)
        try send(status(capture:capture,generation:generation),&state,peer)
        return peer
    }
    private func registry(_ clock: HeldClock) -> BrowserControlRegistry {
        .init(clock:{ clock.now },instanceAlive:{ _ in clock.instanceAlive })
    }

    func testUnacknowledgedBrowserStartContinuesToFenceSignalsWhileControlIsDisconnected() throws {
        let clock = HeldClock(); var state = registry(clock)
        let old = try ready(&state)
        let start = try state.start(.init(peer:old,tabID:2),microphone:false)
        let row = BrowserCallSignal(tabID:2,url:"https://meet.example/2",document:"document-A",remoteAudio:"mixed",state:"active",reason:"activeCall",site:"Synthetic call",generation:"call-A")
        XCTAssertTrue(state.browserOwnsSignal(instance:"profile-A",row:row))
        XCTAssertEqual(state.disconnect(old,holding:[start.id]),[start.id])
        XCTAssertTrue(state.snapshots.isEmpty)
        XCTAssertTrue(state.browserOwnsSignal(instance:"profile-A",row:row),"A held browser Start may already be recording")
        clock.advance(BrowserControlRegistry.heldStartGrace)
        _ = state.settleHeldStarts()
        XCTAssertFalse(state.browserOwnsSignal(instance:"profile-A",row:row))
    }

    func testAStartLostToAWorkerRestartSettlesOkWhenTheNewLinkReportsItsCapture() throws {
        let clock = HeldClock(); var state = registry(clock)
        let old = try ready(&state)
        let start = try state.start(.init(peer:old,tabID:2),microphone:true)
        XCTAssertEqual(state.disconnect(old,holding:[start.id]),[start.id],"the unanswered Start is held, not failed")
        XCTAssertFalse(state.outcomes.contains { $0.requestID == start.id })
        XCTAssertTrue(state.settleHeldStarts().isEmpty,"nothing reports it yet")
        // The restarted worker connects: before its status shows the capture, the call is not
        // started a second time, by Record or by auto-record.
        let new = UUID()
        try state.connect(.init(id:new,role:.control,browser:"Chrome",browserInstance:instance))
        try send(["type":"hello","version":1,"capabilities":["independent-sessions-v1","multi-stream-v1"]],&state,new)
        try send(meetings("call-A"),&state,new)
        try send(status(),&state,new)
        XCTAssertThrowsError(try state.start(.init(peer:new,tabID:2),microphone:true)) { XCTAssertEqual($0 as? BrowserControlStateError,.busy) }
        XCTAssertTrue(state.automaticStarts(microphone:true).isEmpty)
        XCTAssertTrue(state.settleHeldStarts().isEmpty)
        try send(status(capture:"capture-1"),&state,new)
        let settled = state.settleHeldStarts()
        XCTAssertEqual(settled.map(\.requestID),[start.id])
        XCTAssertEqual(settled.first?.ok,true)
        XCTAssertEqual(settled.first?.key,.init(peer:old,tabID:2),"the attempt that issued it completes")
        XCTAssertEqual(settled.first?.settledKey,.init(peer:new,tabID:2))
        XCTAssertEqual(state.heldStartCount,0)
        XCTAssertTrue(state.settleHeldStarts().isEmpty,"it settles exactly once")
    }

    func testAnotherCallOrBrowserNeverSettlesItAndItFailsAtTheDeadline() throws {
        let clock = HeldClock(); var state = registry(clock)
        let old = try ready(&state)
        let start = try state.start(.init(peer:old,tabID:2),microphone:true)
        state.disconnect(old,holding:[start.id])
        _ = try ready(&state,generation:"call-B",capture:"other-call")
        _ = try ready(&state,instance:.init(pid:4242,startSeconds:1_793_000_001),capture:"other-browser")
        XCTAssertTrue(state.settleHeldStarts().isEmpty)
        clock.advance(BrowserControlRegistry.heldStartGrace - 0.01)
        XCTAssertTrue(state.settleHeldStarts().isEmpty)
        clock.advance(0.01)
        let failed = state.settleHeldStarts()
        XCTAssertEqual(failed.map(\.requestID),[start.id])
        XCTAssertEqual(failed.first?.ok,false); XCTAssertEqual(failed.first?.failure,"disconnected")
    }

    func testABrowserExitOrShutdownFailsAHeldStart() throws {
        let clock = HeldClock(); var state = registry(clock)
        var peer = try ready(&state)
        let first = try state.start(.init(peer:peer,tabID:2),microphone:true)
        state.disconnect(peer,holding:[first.id]); clock.exit()
        XCTAssertEqual(state.settleHeldStarts().map { [$0.requestID,$0.failure ?? ""] },[[first.id,"disconnected"]])
        let alive = HeldClock(); state = registry(alive)
        peer = try ready(&state)
        let second = try state.start(.init(peer:peer,tabID:2),microphone:true)
        state.disconnect(peer,holding:[second.id])
        XCTAssertEqual(state.settleHeldStarts(shutdown:true).map { [$0.requestID,$0.failure ?? ""] },[[second.id,"disconnected"]])
    }

    /// #138 review: the extension may publish the capture's status before the Start's result,
    /// which binds the capture (and drops the unbound Start). Either way a user Stop during the
    /// hold ends it quietly, also when the restarted link then reports the call idle.
    func testAUserStopWhileHeldEndsItQuietlyWhicheverArrivedFirst() throws {
        for statusFirst in [false,true] {
            for stopsOne in [false,true] {
                let clock = HeldClock(); var state = registry(clock)
                let old = try ready(&state)
                let start = try state.start(.init(peer:old,tabID:2),microphone:true)
                if statusFirst { try send(status(capture:"capture-1"),&state,old) }
                state.disconnect(old,holding:[start.id])
                if stopsOne { state.rememberUserStop(key:.init(peer:old,tabID:2),captureID:"capture-1") }
                else { _ = state.stopAll(userInitiated:true) }
                _ = try ready(&state) // The restarted worker: the call is idle, the user stopped it.
                let settled = state.settleHeldStarts()
                let label = "status first \(statusFirst), \(stopsOne ? "that capture's Stop" : "Stop All")"
                XCTAssertEqual(settled.map(\.requestID),[start.id],label)
                XCTAssertEqual(settled.first?.userStopped,true,label); XCTAssertNil(settled.first?.failure,label)
                XCTAssertEqual(state.heldStartCount,0,label)
                clock.advance(BrowserControlRegistry.heldStartGrace)
                XCTAssertTrue(state.settleHeldStarts().isEmpty,"\(label): no failure at the deadline")
            }
        }
    }

    /// The same over real pipes: status before the (lost) result, link closes, the user stops,
    /// the restarted link reports the call idle. The app hears one quiet end, never a failure.
    func testTheServiceEndsAHeldStartQuietlyAfterAUserStopWhenStatusCameFirst() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CassiniHeldStart-" + UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        defer { try? FileManager.default.removeItem(at:root) }
        let completions = Completions(), boundOnFirst = Armed(), goneAfterStart = Armed()
        let bound = expectation(description:"capture status bound"), gone = expectation(description:"first link gone")
        let ended = expectation(description:"held Start ended")
        bound.assertForOverFulfill = false; gone.assertForOverFulfill = false; ended.assertForOverFulfill = false
        let service = BrowserControlService(changed:{ peers in
            if peers.contains(where:{ $0.captures.contains { $0.captureID == "capture-1" } }) { boundOnFirst.fulfill() }
            if peers.isEmpty { goneAfterStart.fulfill() }
        },completed:{ outcome,automatic in completions.append(outcome,automatic); ended.fulfill() })
        try service.start(root:root); defer { service.stop() }
        service.setAutoRecord(true,microphone:false)
        let instance = try XCTUnwrap(BrowserInstance.process(getpid()))
        func open() throws -> PipeEndpoint {
            let link = try PipeEndpoint(root:root,role:.control,browser:"Chrome",browserInstance:instance)
            try link.send(JSONSerialization.data(withJSONObject:["type":"hello","version":1,"capabilities":["independent-sessions-v1","multi-stream-v1"]]))
            try link.send(JSONSerialization.data(withJSONObject:meetings("call-A")))
            return link
        }
        var first: PipeEndpoint? = try open()
        try XCTUnwrap(first).send(JSONSerialization.data(withJSONObject:status()))
        guard let data = try XCTUnwrap(first).receive(deadline:DispatchTime.now().uptimeNanoseconds + 3_000_000_000) else { throw BrowserIPCError.closed }
        XCTAssertEqual(try JSONParser.parse(data)["action"]?.string,"start")
        boundOnFirst.arm(bound)
        try XCTUnwrap(first).send(JSONSerialization.data(withJSONObject:status(capture:"capture-1")))
        wait(for:[bound],timeout:3)
        goneAfterStart.arm(gone)
        first = nil // The worker restarts before the Start's result.
        wait(for:[gone],timeout:3)
        service.stopRecordings()
        let second = try open()
        try second.send(JSONSerialization.data(withJSONObject:status()))
        wait(for:[ended],timeout:3)
        XCTAssertEqual(completions.all.count,1)
        XCTAssertEqual(completions.all.first?.0.userStopped,true)
        XCTAssertNil(completions.all.first?.0.failure)
    }

    func testOnlyASentMultiStreamStartOnAClosedLinkIsHeld() throws {
        let clock = HeldClock(); var state = registry(clock)
        let older = try ready(&state,multiStream:false)
        let legacy = try state.start(.init(peer:older,tabID:2),microphone:true)
        XCTAssertEqual(state.disconnect(older,holding:[legacy.id]),[],"an older companion's Start fails at once")
        XCTAssertEqual(state.outcomes.last?.requestID,legacy.id); XCTAssertEqual(state.outcomes.last?.failure,"disconnected")
        // Not named by the service: never sent (its send failed), or the link closed for an
        // unanswered command (timeout). The browser cannot be recording it.
        let silent = try ready(&state)
        let unsent = try state.start(.init(peer:silent,tabID:2),microphone:true)
        XCTAssertEqual(state.disconnect(silent),[])
        XCTAssertEqual(state.outcomes.last?.requestID,unsent.id)
        XCTAssertEqual(state.heldStartCount,0)
        let next = try ready(&state)
        XCTAssertNoThrow(try state.start(.init(peer:next,tabID:2),microphone:true),"nothing held blocks the call")
    }

    /// The user stops while the Start is held (Stop All, or that capture's Stop): it ends quietly
    /// at once, not as a failed start at the deadline nor as a start to announce later.
    func testAUserStopWhileHeldEndsItQuietly() throws {
        let clock = HeldClock(); var state = registry(clock)
        let old = try ready(&state)
        let start = try state.start(.init(peer:old,tabID:2),microphone:true)
        state.disconnect(old,holding:[start.id])
        _ = state.stopAll(userInitiated:true)
        let new = try ready(&state,capture:"capture-1")
        let settled = state.settleHeldStarts()
        XCTAssertEqual(settled.map(\.requestID),[start.id])
        XCTAssertEqual(settled.first?.userStopped,true); XCTAssertEqual(settled.first?.ok,true)
        XCTAssertNil(settled.first?.failure); XCTAssertNil(settled.first?.settledKey)
        XCTAssertTrue(state.automaticStarts(microphone:true).isEmpty,"the stopped call stays stopped")
        _ = new
    }

    /// The whole path over real pipes: the auto-record Start's link closes before its result;
    /// the app hears nothing until the restarted link reports the capture, then one ok.
    func testTheServiceCompletesALostStartOnceWhenTheRestartedLinkReportsTheCapture() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CassiniHeldStart-" + UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        defer { try? FileManager.default.removeItem(at:root) }
        let completions = Completions(), goneAfterStart = Armed()
        let gone = expectation(description:"first link gone"), settled = expectation(description:"held Start settled")
        gone.assertForOverFulfill = false; settled.assertForOverFulfill = false
        let service = BrowserControlService(changed:{ peers in if peers.isEmpty { goneAfterStart.fulfill() } },
                                            completed:{ outcome,automatic in completions.append(outcome,automatic); settled.fulfill() })
        try service.start(root:root); defer { service.stop() }
        service.setAutoRecord(true,microphone:false)
        let instance = try XCTUnwrap(BrowserInstance.process(getpid()))
        func open() throws -> PipeEndpoint {
            let link = try PipeEndpoint(root:root,role:.control,browser:"Chrome",browserInstance:instance)
            try link.send(JSONSerialization.data(withJSONObject:["type":"hello","version":1,"capabilities":["independent-sessions-v1","multi-stream-v1"]]))
            try link.send(JSONSerialization.data(withJSONObject:meetings("call-A")))
            return link
        }
        func receive(_ link: PipeEndpoint, seconds: Double = 3) throws -> JSON {
            guard let data = try link.receive(deadline:DispatchTime.now().uptimeNanoseconds + UInt64(seconds*1_000_000_000)) else { throw BrowserIPCError.closed }
            return try JSONParser.parse(data)
        }
        var first: PipeEndpoint? = try open()
        try XCTUnwrap(first).send(JSONSerialization.data(withJSONObject:status()))
        let start = try receive(try XCTUnwrap(first))
        XCTAssertEqual(start["action"]?.string,"start"); XCTAssertEqual(start["callGeneration"]?.string,"call-A")
        goneAfterStart.arm(gone)
        first = nil // The worker restarts before it answers.
        wait(for:[gone],timeout:3)
        XCTAssertTrue(completions.all.isEmpty,"a lost Start is not failed while it may be recording")
        let second = try open()
        try second.send(JSONSerialization.data(withJSONObject:status(capture:"capture-1")))
        wait(for:[settled],timeout:3)
        let outcome = try XCTUnwrap(completions.all.first)
        XCTAssertEqual(completions.all.count,1)
        XCTAssertEqual(outcome.0.requestID,start["requestId"]?.string)
        XCTAssertTrue(outcome.0.ok); XCTAssertTrue(outcome.1,"it keeps its automatic origin")
        XCTAssertEqual(outcome.0.settledKey?.tabID,2); XCTAssertNotEqual(outcome.0.settledKey,outcome.0.key)
        XCTAssertThrowsError(try receive(second,seconds:0.3),"no second Start for the recording call")
    }
}
