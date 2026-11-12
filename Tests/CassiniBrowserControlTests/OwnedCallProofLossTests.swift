// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
import Foundation
import AVFoundation
import CassiniKit
import CassiniRecording
@testable import CassiniBrowserControl

private final class OwnerProofClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval = 0
    func now() -> TimeInterval { lock.withLock { value } }
    func set(_ value: TimeInterval) { lock.withLock { self.value = value } }
}

@MainActor private final class OwnerProofInput: CaptureInput {
    let kind: String, origin: UInt64, firstAt: Double
    var starts = 0
    private var sink: RecordingSink?
    init(_ kind: String, origin: UInt64, firstAt: Double = 0) { self.kind = kind; self.origin = origin; self.firstAt = firstAt }
    func authorize() async throws {}
    func start(sink: RecordingSink, failure: @escaping @Sendable (String) -> Void) throws {
        starts += 1; self.sink = sink
        let format = AVAudioFormat(standardFormatWithSampleRate:8000,channels:1)!
        let buffer = AVAudioPCMBuffer(pcmFormat:format,frameCapacity:800)!
        buffer.frameLength = 800
        for index in 0..<800 { buffer.floatChannelData![0][index] = 0.25 }
        sink.receive(buffer,hostTime:origin + AVAudioTime.hostTime(forSeconds:firstAt),id:kind,label:"Generated input",kind:kind)
    }
    func stop() { sink = nil }
}

final class OwnedCallProofLossTests: XCTestCase {
    private func call(document: String = "chrome-A", source: String = "hook-A", generation: String = "call-A") -> BrowserVerifiedCall {
        .init(profile:"profile-A",tab:2,browserDocument:document,sourceDocument:source,generation:generation)
    }
    private func accepted(_ clock: OwnerProofClock) throws -> (BrowserAutomaticAdmissionStore,BrowserAudioStart) {
        let store = BrowserAutomaticAdmissionStore(clock:{ clock.now() })
        let request = BrowserControlRequest(id:"automatic-owner",key:.init(peer:UUID(),tabID:2),action:.start,data:Data(),automaticCall:call())
        try store.issue(request,browser:nil,generation:"call-A",document:"hook-A",microphone:true,verifiedConfigured:true,deadline:5)
        let start = try store.authorize(.init(captureID:"running-browser",timelineOriginMs:0,microphone:true,callGeneration:"call-A",documentGeneration:"hook-A",requestID:.string(request.id)),browser:nil)
        return (store,start)
    }
    @MainActor func testRunningBrowserInputFallbackAndMeRestartSurviveProofLoss() async throws {
        for transition in ["worker-restart","auto-off","reload"] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("OwnedProof-"+UUID().uuidString)
            defer { try? FileManager.default.removeItem(at:root) }
            let clock = OwnerProofClock(), (store,start) = try accepted(clock)
            let gate = try XCTUnwrap(start.inputGate)
            let owner = try OwnedBrowserCapture(parent:root,title:"Generated owned call",microphone:true,managedBrowser:true)
            let originalID = owner.snapshot.manifest.id, originalFolder = owner.snapshot.directory
            try owner.browserTrack(id:"remote",label:"Generated remote",kind:"remote",sampleRate:8000,channels:1)
            let origin = AVAudioTime.hostTime(forSeconds:ProcessInfo.processInfo.systemUptime)
            let mic = OwnerProofInput("microphone",origin:origin), restartedMic = OwnerProofInput("microphone",origin:origin,firstAt:3)
            let system = OwnerProofInput("system",origin:origin,firstAt:2)
            var microphones = [mic,restartedMic]
            let inputs = CaptureInputLifecycle(capture:owner,originHostTime:origin,
                microphone:{ microphones.removeFirst() },system:{ system },failure:{ message in XCTFail("Proof loss is not a source failure: \(message)") },
                admission:{ gate.permits },inputGate:gate)
            try await inputs.start()
            try gate.admit { try owner.browserAudio(id:"remote",sequence:0,offsetMs:0,pcm:Data(repeating:1,count:1600)) }
            XCTAssertTrue(gate.hasOpened); XCTAssertFalse(inputs.hasRunningInputs,"Browser PCM needs no native inputs")
            if transition == "auto-off" { store.cancelAllPending(automaticOnly:true) }
            if transition == "worker-restart" { store.complete("automatic-owner") }
            clock.set(6); store.update(pending:[:],owned:[:],ended:[])
            if transition == "reload" { store.update(pending:[:],owned:[call(document:"chrome-B",source:"hook-B"):11],ended:[]) }
            XCTAssertNil(store.endReason(start.captureID)); XCTAssertTrue(gate.permits)
            try owner.browserLost(atMs:1000,transportAlive:true)
            try await inputs.fallback()
            XCTAssertEqual(system.starts,1); XCTAssertTrue(owner.snapshot.isSystemFallback)
            XCTAssertEqual(owner.snapshot.manifest.source,"chromium","An owned browser call keeps its route identity")
            XCTAssertEqual(owner.snapshot.manifest.id,originalID); XCTAssertEqual(owner.snapshot.directory,originalFolder)
            let off = try await inputs.select(me:false,others:true,atMs:2500)
            let on = try await inputs.select(me:true,others:true,atMs:3000)
            XCTAssertTrue(off.isEmpty); XCTAssertTrue(on.isEmpty)
            XCTAssertEqual(restartedMic.starts,0,"Separated Me must not open hardware during loss grace")
            XCTAssertTrue(inputs.failedSides.isEmpty)
            XCTAssertEqual(owner.snapshot.phase,.recording)
            clock.set(124.999); XCTAssertNil(store.endReason(start.captureID)); XCTAssertTrue(gate.permits)
            clock.set(125); XCTAssertEqual(store.endReason(start.captureID),.pageGone); XCTAssertFalse(gate.permits)
            try await inputs.stop(); try await owner.finish()
        }
    }
    @MainActor func testPositiveEndAndUserStopStillFenceTheRunningOwner() throws {
        for reason: CaptureEndReason in [.callEnded,.user] {
            let clock = OwnerProofClock(), (store,start) = try accepted(clock)
            let gate = try XCTUnwrap(start.inputGate)
            try gate.acceptOwner(); clock.set(1)
            if reason == .callEnded { store.update(pending:[:],owned:[:],ended:[call()]) }
            else { store.cancel(start.captureID,reason:.user) }
            XCTAssertEqual(store.endReason(start.captureID),reason)
            XCTAssertThrowsError(try gate.admit { XCTFail("Ended owners cannot open replacement inputs") })
            clock.set(2); store.update(pending:[:],owned:[call():7],ended:[])
            XCTAssertEqual(store.endReason(start.captureID),reason)
            XCTAssertFalse(gate.permits,"Later active evidence cannot undo Stop or a matching positive end")
        }
    }
    func testReloadedDocumentIsLossNotPositiveEndForSeparatedOwner() throws {
        for generation in ["call-A","call-B"] {
            let clock = OwnerProofClock(), (store,start) = try accepted(clock)
            let gate = try XCTUnwrap(start.inputGate)
            try gate.acceptOwner()
            clock.set(1); store.update(pending:[:],owned:[:],ended:[])
            clock.set(2)
            store.update(pending:[:],owned:[call(document:"chrome-B",source:"hook-B",generation:generation):7],ended:[])
            if generation == "call-B" {
                XCTAssertEqual(store.endReason(start.captureID),.callEnded)
                XCTAssertFalse(gate.permits)
            } else {
                XCTAssertNil(store.endReason(start.captureID),"A reload is not affirmative callEnded")
                XCTAssertTrue(gate.permits,"The accepted owner keeps its existing grace and route")
                clock.set(120.999); XCTAssertNil(store.endReason(start.captureID))
                clock.set(121); XCTAssertEqual(store.endReason(start.captureID),.pageGone)
            }
        }
    }
    func testReloadedDocumentIsLossNotPositiveEndForMixedOwnerWithAutoOff() throws {
        for generation in ["call-A","call-B"] {
            let id = UUID()
            func peer(_ document: String, _ source: String, _ generation: String, _ seq: Int) -> SignalCallPolicy.Peer {
                let row = BrowserCallSignal(tabID:2,url:"https://call.example/",document:document,remoteAudio:"mixed",state:"active",reason:"activeCall",site:"Generated call",generation:generation,sourceDocument:source)
                let key = SignalCallPolicy.Key(instance:"profile-A",tab:2,document:document,generation:generation,sourceDocument:source)
                return .init(id:id,order:1,snapshot:.init(instance:"profile-A",sequence:seq,tabs:[row]),active:[key],expiredAt:[key:seq == 0 ? 5 : 7])
            }
            var policy = SignalCallPolicy()
            policy.update([peer("chrome-A","hook-A","call-A",0)],now:0); policy.advance(now:0,enabled:true)
            let reservation = try XCTUnwrap(policy.reserve()); policy.didStart(reservation)
            policy.update([],now:1)
            policy.update([peer("chrome-B","hook-B",generation,1)],now:2)
            policy.advance(now:2,enabled:false)
            if generation == "call-B" { XCTAssertEqual(policy.retiring,.callEnded) }
            else {
                XCTAssertNil(policy.retiring,"Changed document evidence starts loss handling, not an end")
                XCTAssertTrue(policy.mayOpen(reservation)); XCTAssertEqual(policy.reservation,reservation)
                XCTAssertEqual(policy.calls.count,1,"Auto off cannot admit another association")
                policy.advance(now:120.999,enabled:false); XCTAssertNil(policy.retiring)
                policy.advance(now:121,enabled:false); XCTAssertEqual(policy.retiring,.pageGone)
            }
        }
    }
}
