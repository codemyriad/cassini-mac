// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
import Foundation
import CassiniKit
@_spi(Testing) import CassiniRecording
@_spi(Testing) @testable import CassiniBrowserControl

/// Real writer checkpoints and real control pipes. Every wait is for an event; a
/// heartbeat deliberately queued after rejection proves no resume preceded it.
final class R94CommittedResumeTests: XCTestCase, @unchecked Sendable {
    func testHeldCheckpointPublishesExactFractionalSeamAndReconnectUsesItAgain() async throws {
        try await exercise(held:true,atMs:96_027.15)
    }
    func testInitialStandInPreservesZero() async throws { try await exercise(atMs:0) }
    func testFailedCheckpointNeverAuthorizesResume() async throws {
        for phase in [RecordingCheckpointPhase.audioSynchronized,.metadataSynchronized,.metadataPublished] {
            try await exercise(failing:phase,atMs:96_027.15)
        }
    }
    func testStopDuringHeldCheckpointNeverSendsResume() async throws {
        try await exercise(held:true,stop:true,atMs:96_027.15)
    }
    func testStopAfterReferenceReadIsRevalidatedAtDispatch() async throws {
        try await exercise(stopAtDispatch:true,atMs:96_027.15)
    }
    func testNoneLostAndDeselectedSourcesAreNotResumeTargets() async throws {
        let fixture = try AudioFixture()
        do {
            let owner = try OwnedBrowserCapture(parent:fixture.root.appendingPathComponent("Library"),title:"Synthetic call",microphone:false)
            try owner.browserLost(atMs:100)
            let none = expectation(description:"none/lost rejected")
            owner.withCommittedResume { XCTAssertNil($0); none.fulfill() }
            await fulfillment(of:[none],timeout:5)
            let writer = owner.nativeWriter(side:.others)
            try writer.addTrack(id:"output",label:"Others",kind:"system",sampleRate:8000,channels:1)
            try writer.appendNative(id:"output",pcm:Data(repeating:1,count:1600),offsetMs:150)
            try await owner.select(me:true,others:false,atMs:300)
            let off = expectation(description:"selection revalidated")
            owner.withCommittedResume { XCTAssertNil($0); off.fulfill() }
            await fulfillment(of:[off],timeout:5)
            try await owner.finish()
        } catch { await fixture.finish(); throw error }
        await fixture.finish()
    }

    func testAReferenceCannotEscapeItsSerializedCallback() async throws {
        let fixture = try AudioFixture(), reference = R94ReferenceBox()
        do {
            let owner = try OwnedBrowserCapture(parent:fixture.root.appendingPathComponent("Library"),title:"Synthetic stand-in",microphone:false,browser:false)
            try fixture.broker.ownNative(owner)
            let writer = owner.nativeWriter(side:.others)
            try writer.addTrack(id:"output",label:"Others",kind:"system",sampleRate:8000,channels:1)
            try writer.appendNative(id:"output",pcm:Data(repeating:1,count:1600),offsetMs:0)
            let read = expectation(description:"reference copied")
            owner.withCommittedResume { reference.store($0); read.fulfill() }
            await fulfillment(of:[read],timeout:5); await owner.settled()
            let copied = try XCTUnwrap(reference.value)
            XCTAssertThrowsError(try copied.dispatch { XCTFail("Expired reference was dispatched") })
            try await owner.select(me:true,others:false,atMs:1000)
            XCTAssertThrowsError(try copied.dispatch { XCTFail("Old source seam was dispatched") })
        } catch { await fixture.finish(); throw error }
        await fixture.finish()
    }

    private func exercise(held: Bool = false, failing: RecordingCheckpointPhase? = nil,
                          stop: Bool = false, stopAtDispatch: Bool = false, atMs: Double) async throws {
        let peers = R94Peers(), gate = DispatchSemaphore(value:0), dispatchGate = DispatchSemaphore(value:0)
        let entered = XCTestExpectation(description:"checkpoint entered"), dispatchEntered = XCTestExpectation(description:"dispatch eligibility entered")
        let fixture = try AudioFixture(controlClock:{ peers.clock.now },canStart:{
            if stopAtDispatch { dispatchEntered.fulfill(); XCTAssertEqual(dispatchGate.wait(timeout:.now()+5),.success) }
            return true
        },changed:{ peers.changed($0) })
        defer { gate.signal(); dispatchGate.signal() }
        do {
            var client: PipeEndpoint? = try connect(fixture)
            await fulfillment(of:[peers.ready],timeout:5)
            var key = try XCTUnwrap(peers.key)
            let owner: OwnedBrowserCapture
            if atMs == 0 {
                owner = try OwnedBrowserCapture(parent:fixture.root.appendingPathComponent("Library"),title:"Synthetic call",microphone:false,browser:false)
                try fixture.broker.ownNative(owner,timelineOriginMs:1_793_500_000_000)
            } else {
                let audio = try fixture.client()
                let started = try audio.request(["type":"start","version":1,"independent":true,"captureId":"r94","timelineOriginMs":Int(Date().timeIntervalSince1970*1000),"microphone":false,"title":"Synthetic call"])
                XCTAssertEqual(started["type"]?.string,"started")
                owner = try XCTUnwrap(fixture.broker.activeCaptures.first)
                let closed = fixture.closures.next("audio transport lost")
                audio.end(); await fulfillment(of:[closed],timeout:5)
            }
            let identity = try XCTUnwrap(fixture.broker.standInIdentity(owner))
            let writer = owner.nativeWriter(side:.others)
            try writer.addTrack(id:"output",label:"Others",kind:"system",sampleRate:8000,channels:1)
            owner.setCheckpointObserver { phase in
                guard phase == .metadataSynchronized else {
                    if phase == failing { throw CocoaError(.fileWriteOutOfSpace) }; return
                }
                if held { entered.fulfill(); XCTAssertEqual(gate.wait(timeout:.now()+5),.success) }
                if phase == failing { throw CocoaError(.fileWriteOutOfSpace) }
            }
            let writing = Task.detached { Result { try writer.appendNative(id:"output",pcm:Data(repeating:1,count:1600),offsetMs:atMs) } }
            if held { await fulfillment(of:[entered],timeout:5) } else { _ = await writing.value }
            let armed = expectation(description:"resume resolved"), count = R94Count()
            fixture.service.resumeMeeting(key,captureID:identity.captureID,timelineOriginMs:identity.timelineOriginMs,owner:owner,expectedGeneration:"call-A") { generation,id in
                count.record(generation:generation,id:id); armed.fulfill()
            }
            if held {
                // Disk cannot block control/heartbeat processing. No callback can
                // run before the writer's checkpoint completes.
                fixture.service.tickHeartbeats(); XCTAssertEqual(count.total,0)
                if stop { XCTAssertTrue(owner.requestEnd(.user)) }
                gate.signal(); _ = await writing.value
            }
            if failing == nil { try await writing.value.get() }
            if stopAtDispatch {
                await fulfillment(of:[dispatchEntered],timeout:5)
                XCTAssertTrue(owner.requestEnd(.user)); dispatchGate.signal()
            }
            await fulfillment(of:[armed],timeout:5)
            let rejected = failing != nil || stop || stopAtDispatch
            XCTAssertEqual(count.total,1); XCTAssertEqual(count.accepted,!rejected)
            if rejected {
                // A real heartbeat after the attempted resume is the pipe fence.
                // Its arrival first proves no resume was queued, without a sleep.
                peers.clock.advance()
                fixture.service.tickHeartbeats()
                XCTAssertEqual(try receive(XCTUnwrap(client))["type"]?.string,"ping")
            } else {
                let command = try receive(XCTUnwrap(client))
                let persisted = try RecordingLoader.load(directory:owner.snapshot.directory).events?.last { $0.type == "othersSource" }
                XCTAssertEqual(persisted?.atMs,atMs)
                XCTAssertEqual(command["resumeCapture"]?["lostAtMs"]?.double,atMs,"\(command)")
                XCTAssertEqual(command["resumeCapture"]?["captureId"]?.string,identity.captureID)
                XCTAssertEqual(command["resumeCapture"]?["timelineOriginMs"]?.int,identity.timelineOriginMs)
                // A worker/control reconnect must carry the same committed seam,
                // with a new request id; it cannot substitute reconnection time.
                let previous = command["requestId"]?.string
                peers.clock.advance(); fixture.service.tickHeartbeats()
                XCTAssertEqual(try receive(XCTUnwrap(client))["type"]?.string,"ping","No duplicate ask preceded the pipe fence")
                client = nil
                peers.reset(excluding:key.peer); client = try connect(fixture)
                await fulfillment(of:[peers.ready],timeout:5)
                key = try XCTUnwrap(peers.key)
                let rearmed = expectation(description:"reconnected resume resolved")
                fixture.service.resumeMeeting(key,captureID:identity.captureID,timelineOriginMs:identity.timelineOriginMs,owner:owner,expectedGeneration:"call-A") { generation,id in
                    XCTAssertEqual(generation,"call-A"); XCTAssertNotNil(id); rearmed.fulfill()
                }
                await fulfillment(of:[rearmed],timeout:5)
                let reconnect = try receive(XCTUnwrap(client))
                XCTAssertEqual(reconnect["resumeCapture"]?["lostAtMs"]?.double,atMs,"\(reconnect)")
                XCTAssertNotEqual(reconnect["requestId"]?.string,previous)
                peers.clock.advance(); fixture.service.tickHeartbeats()
                XCTAssertEqual(try receive(XCTUnwrap(client))["type"]?.string,"ping")
            }
            owner.setCheckpointObserver(nil)
        } catch { gate.signal(); dispatchGate.signal(); await fixture.finish(); throw error }
        await fixture.finish()
    }
    private func connect(_ fixture: AudioFixture) throws -> PipeEndpoint {
        let client = try PipeEndpoint(root:fixture.ipc,role:.control,browser:"Chrome")
        for value: [String:Any] in [
            ["type":"hello","version":1,"capabilities":["independent-sessions-v1","multi-stream-v1","page-state-v1","resume-capture-v1","heartbeat-v1"]],
            ["type":"meetings","meetings":[["tabId":2,"title":"Synthetic call","url":"https://meet.example/2","sourceCount":1,"heard":true,"callGeneration":"call-A"]]],
            ["type":"status","recording":false,"tabId":NSNull(),"path":NSNull(),"message":"Ready","sessions":[]]] {
            try client.send(JSONSerialization.data(withJSONObject:value))
        }
        return client
    }
    private func receive(_ client: PipeEndpoint) throws -> JSON {
        try JSONParser.parse(XCTUnwrap(client.receive(deadline:DispatchTime.now().uptimeNanoseconds+5_000_000_000)))
    }
}
private final class R94Count: @unchecked Sendable {
    private let lock = NSLock(); private var calls = 0, ok = false
    var total: Int { lock.withLock { calls } }; var accepted: Bool { lock.withLock { ok } }
    func record(generation: String?, id: String?) { lock.withLock { calls += 1; ok = generation == "call-A" && id != nil } }
}
private final class R94Clock: @unchecked Sendable {
    private let lock = NSLock(); private var time: UInt64 = 0
    var now: UInt64 { lock.withLock { time } }
    func advance() { lock.withLock { time += 10_000 } }
}
private final class R94Peers: @unchecked Sendable {
    private let lock = NSLock(); private var current: BrowserMeetingKey?, delivered = false, excluded: UUID?
    let clock = R94Clock()
    private var event = XCTestExpectation(description:"control reconciled")
    var ready: XCTestExpectation { lock.withLock { event } }
    var key: BrowserMeetingKey? { lock.withLock { current } }
    func reset(excluding id: UUID) { lock.withLock { excluded = id; current = nil; delivered = false; event = XCTestExpectation(description:"control reconnected") } }
    func changed(_ peers: [BrowserControlPeerSnapshot]) {
        lock.withLock {
            guard !delivered, let key = peers.first(where:{ $0.reconciled && $0.id != excluded })?.meetings.first?.key else { return }
            current = key; delivered = true; event.fulfill()
        }
    }
}

private final class R94ReferenceBox: @unchecked Sendable {
    private let lock = NSLock(); private var stored: OwnedBrowserCapture.ResumeReference?
    var value: OwnedBrowserCapture.ResumeReference? { lock.withLock { stored } }
    func store(_ reference: OwnedBrowserCapture.ResumeReference?) { lock.withLock { stored = reference } }
}
