// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
import Foundation
import AVFoundation
import CassiniRecording
@testable import CassiniBrowserControl

private final class BrowserMePCMProbe: RecordedPCMObserver, @unchecked Sendable {
    struct Sample { let source: RecordedPCMSource, pcm: Data, offset: Double }
    private let lock = NSLock()
    private var samples: [Sample] = []
    private var ended: [String] = []
    func sourceEnded(id: String) { lock.withLock { ended.append(id) } }
    var endedIDs: [String] { lock.withLock { ended } }
    func offer(source: RecordedPCMSource, pcm: Data, offsetMs: Double) { lock.withLock { samples.append(.init(source:source,pcm:pcm,offset:offsetMs)) } }
    var snapshot: [Sample] { lock.withLock { samples } }
}

@MainActor private final class PrivacyInput: CaptureInput {
    var authorizations = 0, starts = 0, stops = 0
    func authorize() async throws { authorizations += 1 }
    func start(sink: RecordingSink, failure: @escaping @Sendable (String) -> Void) throws { starts += 1 }
    func stop() { stops += 1 }
}
final class BrowserLocalMeTests: XCTestCase, @unchecked Sendable {
    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        return root
    }
    private let tone = Data((0..<800).flatMap { i -> [UInt8] in
        let sample = Int16(sin(Double(i)*2 * .pi*440/8000)*10000)
        return [UInt8(truncatingIfNeeded:sample),UInt8(truncatingIfNeeded:sample >> 8)]
    })
    func testLocalSelectionMuteMeterAndAnalysisAreIndependentOfOthers() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at:root) }
        let owner = try OwnedBrowserCapture(parent:root,title:"Synthetic call",microphone:true,captureLocal:true,managedBrowser:true)
        owner.enableSourceOutcomes()
        let probe = BrowserMePCMProbe(); owner.pcmObservers.set(probe)
        try owner.browserTrack(id:"me",label:"Me",kind:"local",sampleRate:8000,channels:1,sourceTrackId:"sender")
        try owner.browserTrack(id:"them",label:"Remote",kind:"remote",sampleRate:8000,channels:1)
        try owner.browserAudio(id:"me",sequence:0,offsetMs:0,pcm:tone)
        XCTAssertGreaterThan(owner.snapshot.browserMeLevel,0.1)
        XCTAssertEqual(owner.snapshot.browserLevel,0)
        XCTAssertEqual(probe.snapshot.last?.source.kind,"local")
        try await owner.select(me:true,others:false,atMs:100)
        try owner.browserAudio(id:"me",sequence:1,offsetMs:100,pcm:Data(repeating:0,count:1600))
        XCTAssertEqual(owner.snapshot.browserMeLevel,0,"Meeting mute contributes silence, never hardware PCM")
        XCTAssertEqual(owner.snapshot.manifest.tracks.first { $0.kind == "local" }?.frames,1600)
        try await owner.select(me:false,others:true,atMs:200)
        let heard = probe.snapshot.count
        try owner.browserAudio(id:"me",sequence:2,offsetMs:200,pcm:tone)
        XCTAssertEqual(probe.snapshot.count,heard)
        XCTAssertEqual(owner.snapshot.browserMeLevel,0)
        try owner.browserAudio(id:"them",sequence:0,offsetMs:200,pcm:tone)
        XCTAssertGreaterThan(owner.snapshot.browserLevel,0.1)
        try await owner.select(me:true,others:true,atMs:350)
        try owner.browserAudio(id:"me",sequence:3,offsetMs:300,pcm:tone)
        let last = try XCTUnwrap(probe.snapshot.last)
        XCTAssertEqual(last.source.kind,"local"); XCTAssertEqual(last.offset,350)
        XCTAssertEqual(last.pcm.count,800)
        try owner.trackEnd(id:"me",reason:"ended",droppedFrames:0)
        XCTAssertEqual(owner.snapshot.browserMeLevel,0)
        try await owner.finish()
    }
    @MainActor func testNoNativeMicrophoneOnStartSelectFallbackOrReload() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at:root) }
        let owner = try OwnedBrowserCapture(parent:root,title:"Privacy",microphone:true,captureLocal:true,managedBrowser:true)
        owner.enableSourceOutcomes()
        let mic = PrivacyInput(), system = PrivacyInput()
        let inputs = CaptureInputLifecycle(capture:owner,originHostTime:mach_absolute_time(),microphone:{ mic },system:{ system },failure:{ _ in },openBound:{})
        try await inputs.start()
        XCTAssertEqual(mic.authorizations,0,"Start must not authorize hardware")
        if mic.authorizations != 0 { try await inputs.stop(); try await owner.finish(); return }
        try await inputs.select(me:false,others:true,atMs:0)
        try await inputs.select(me:true,others:true,atMs:0)
        XCTAssertEqual(mic.authorizations,0,"Selecting browser Me must not authorize hardware")
        if mic.authorizations != 0 { try await inputs.stop(); try await owner.finish(); return }
        try owner.browserTrack(id:"old",label:"Me",kind:"local",sampleRate:8000,channels:1,sourceTrackId:"sender")
        try owner.browserAudio(id:"old",sequence:0,offsetMs:0,pcm:tone)
        try owner.browserLost(atMs:100,transportAlive:true)
        XCTAssertEqual(owner.snapshot.browserMeLevel,0)
        try await inputs.update(); try await inputs.fallback()
        try owner.browserTrack(id:"new",label:"Me",kind:"local",sampleRate:8000,channels:1,sourceTrackId:"new-sender")
        try owner.browserAudio(id:"new",sequence:0,offsetMs:400,pcm:tone)
        XCTAssertFalse(owner.snapshot.restoreReady,"Sender PCM alone must not stop Others fallback")
        try owner.browserTrack(id:"remote-return",label:"Others",kind:"remote",sampleRate:8000,channels:1)
        try owner.browserAudio(id:"remote-return",sequence:0,offsetMs:450,pcm:tone)
        XCTAssertTrue(owner.snapshot.restoreReady)
        try await inputs.restoreBrowser(atMs:500)
        try owner.browserAudio(id:"new",sequence:1,offsetMs:500,pcm:tone)
        XCTAssertEqual(mic.authorizations,0); XCTAssertEqual(mic.starts,0)
        XCTAssertTrue(inputs.refusedSides[.me] == nil)
        XCTAssertEqual(system.starts,1)
        XCTAssertFalse(owner.snapshot.manifest.tracks.contains { $0.kind == "microphone" })
        XCTAssertEqual(owner.snapshot.manifest.tracks.filter { $0.kind == "local" && $0.frames > 0 }.count,2)
        try await inputs.stop(); try await owner.finish()
    }
    func testFreshSelectedSenderPCMCountsDuringControlGapsEvenWhenMuted() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at:root) }
        let owner = try OwnedBrowserCapture(parent:root,title:"Me only",microphone:true,captureLocal:true,managedBrowser:true)
        try await owner.select(me:true,others:false,atMs:0)
        try owner.browserTrack(id:"me",label:"Me",kind:"local",sampleRate:8000,channels:1)
        try owner.browserAudio(id:"me",sequence:0,offsetMs:0,pcm:Data(repeating:0,count:1600))
        let source = owner.snapshot
        XCTAssertEqual(source.levelTimestamp,0)
        XCTAssertGreaterThan(source.meLevelTimestamp,0)
        XCTAssertEqual(source.browserMeLevel,0,"Mute is PCM liveness without voice energy")
        XCTAssertTrue(source.hasFreshBrowserPCM(nativeMe:owner.nativeMe,at:source.meLevelTimestamp+0.5))
        XCTAssertFalse(source.hasFreshBrowserPCM(nativeMe:true,at:source.meLevelTimestamp+0.5))
        XCTAssertFalse(source.hasFreshBrowserPCM(nativeMe:false,at:source.meLevelTimestamp+1.1))
        try owner.browserLost(atMs:100,transportAlive:true)
        XCTAssertFalse(owner.snapshot.hasFreshBrowserPCM(nativeMe:false,at:source.meLevelTimestamp+0.5))
        try await owner.finish()
    }
    @MainActor func testSenderBeforeOthersKeepsFallbackUntilOthersPCMForBothSelections() async throws {
        for me in [false,true] {
            let root = try root(); defer { try? FileManager.default.removeItem(at:root) }
            let owner = try OwnedBrowserCapture(parent:root,title:"Others readiness",microphone:me,captureLocal:true,managedBrowser:true)
            let mic = PrivacyInput(), system = PrivacyInput()
            let inputs = CaptureInputLifecycle(capture:owner,originHostTime:mach_absolute_time(),microphone:{mic},system:{system},failure:{_ in})
            try await inputs.start()
            try owner.browserLost(atMs:100,transportAlive:true)
            try await inputs.fallback()
            let output = owner.nativeWriter(side:.others)
            try output.addTrack(id:"system-proof",label:"Others",kind:"system",sampleRate:8000,channels:1)
            try output.appendNative(id:"system-proof",pcm:tone,offsetMs:100)
            let events = owner.snapshot.manifest.events
            try owner.browserTrack(id:"local",label:"Me",kind:"local",sampleRate:8000,channels:1)
            try owner.browserAudio(id:"local",sequence:0,offsetMs:300,pcm:tone)
            XCTAssertFalse(owner.snapshot.restoreReady)
            XCTAssertNil(owner.snapshot.browserReturnPCMAt)
            XCTAssertTrue(owner.snapshot.usingSystem)
            XCTAssertTrue(inputs.hasRunningInputs)
            do { try await inputs.restoreBrowser(atMs:350); XCTFail("Sender-only return must not pause Others") }
            catch { XCTAssertEqual(system.stops,0) }
            try output.appendNative(id:"system-proof",pcm:tone,offsetMs:200)
            XCTAssertEqual(owner.snapshot.manifest.tracks.first { $0.kind == "system" }?.frames,1600)
            XCTAssertEqual(owner.snapshot.manifest.events,events)
            try owner.browserTrack(id:"remote",label:"Others",kind:"remote",sampleRate:8000,channels:1)
            try owner.browserAudio(id:"remote",sequence:0,offsetMs:400,pcm:tone)
            XCTAssertTrue(owner.snapshot.restoreReady)
            XCTAssertEqual(owner.snapshot.browserReturnPCMAt,400)
            try await inputs.restoreBrowser(atMs:500)
            XCTAssertTrue(owner.snapshot.browserAlive)
            XCTAssertFalse(owner.snapshot.usingSystem)
            XCTAssertTrue(owner.snapshot.manifest.tracks.contains { $0.kind == "remote" && $0.ended != true })
            XCTAssertEqual(owner.snapshot.manifest.tracks.contains { $0.kind == "local" && $0.ended != true },me)
            XCTAssertEqual(mic.starts,0)
            try await inputs.stop(); try await owner.finish()
        }
    }
    func testOthersRestoreWriterRejectsLocalOnlySource() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at:root) }
        let session = try RecordingSession(parent:root,title:"Others contract",source:"chromium")
        try session.transition(events:[.init(atMs:0,type:"selection",reason:"start",me:true,others:true)])
        try session.transition(starting:[.init(id:"system",label:"Others",kind:"system",sampleRate:8000,channels:1)],events:[.init(atMs:1,type:"othersSource",source:"system",reason:"lost")])
        let before = session.manifest.events
        XCTAssertThrowsError(try session.transition(starting:[.init(id:"sender",label:"Me",kind:"local",sampleRate:8000,channels:1,sourceTrackId:"sender")],ending:["system"],events:[.init(atMs:2,type:"othersSource",source:"browser",reason:"restored")]))
        XCTAssertEqual(session.manifest.events,before)
        try session.finish()
    }
    @MainActor func testMeOnlySelectionIsRefusedWhilePageIsUnavailable() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at:root) }
        let owner = try OwnedBrowserCapture(parent:root,title:"Disconnected page",microphone:true,captureLocal:true,managedBrowser:true)
        let mic = PrivacyInput(), system = PrivacyInput()
        let inputs = CaptureInputLifecycle(capture:owner,originHostTime:mach_absolute_time(),microphone:{mic},system:{system},failure:{_ in})
        try await inputs.start()
        try owner.browserLost(atMs:100,transportAlive:true)
        try await inputs.fallback()
        var refused = false
        do { try await owner.select(me:true,others:false,atMs:200) } catch { refused = true }
        XCTAssertTrue(refused,"A disconnected browser cannot supply Me-only")
        XCTAssertFalse(owner.snapshot.browserAlive); XCTAssertTrue(owner.snapshot.others)
        refused = false
        do { try await inputs.select(me:true,others:false,atMs:200) } catch { refused = true }
        XCTAssertTrue(refused)
        XCTAssertEqual(system.stops,0,"Rejected selection must not interrupt Others")
        try await inputs.stop(); try await owner.finish()
    }
    @MainActor func testMeOnlyLossRequestsSaveWithoutOpeningFallbackDevices() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at:root) }
        let owner = try OwnedBrowserCapture(parent:root,title:"Only Me",microphone:true,captureLocal:true,managedBrowser:true)
        owner.enableSourceOutcomes()
        let mic = PrivacyInput(), system = PrivacyInput()
        let inputs = CaptureInputLifecycle(capture:owner,originHostTime:mach_absolute_time(),microphone:{ mic },system:{ system },failure:{ _ in })
        try await inputs.start(); try await inputs.select(me:true,others:false,atMs:0)
        try owner.browserTrack(id:"old",label:"Me",kind:"local",sampleRate:8000,channels:1)
        try owner.browserAudio(id:"old",sequence:0,offsetMs:0,pcm:tone)
        try owner.browserLost(atMs:100,transportAlive:true)
        try await inputs.fallback()
        XCTAssertTrue(owner.needsBrowserMeLossStop)
        XCTAssertFalse(owner.snapshot.others)
        XCTAssertEqual(mic.authorizations,0); XCTAssertEqual(system.authorizations,0)
        XCTAssertEqual(mic.starts,0); XCTAssertEqual(system.starts,0)
        try await inputs.stop(); try await owner.finish(reason:.pageGone,atMs:100)
        XCTAssertEqual(owner.snapshot.manifest.problemKind,"capture")
    }
    func testBrowserMeMeterRejectsDCUsingCompleteWindowsAndNeverAcceptsNativePCM() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at:root) }
        let owner = try OwnedBrowserCapture(parent:root,title:"DC privacy",microphone:true,captureLocal:true)
        let native = owner.nativeWriter(side:.me)
        try native.addTrack(id:"hardware",label:"OS mic",kind:"microphone",sampleRate:8000,channels:1)
        try native.appendNative(id:"hardware",pcm:tone,offsetMs:0)
        try native.finish(problem:nil)
        XCTAssertTrue(owner.snapshot.manifest.tracks.isEmpty)
        try owner.browserTrack(id:"me",label:"Me",kind:"local",sampleRate:8000,channels:2)
        try owner.browserAudio(id:"me",sequence:0,offsetMs:0,pcm:Data((0..<800).flatMap { _ in [UInt8(0),64,0,192] }))
        XCTAssertEqual(owner.snapshot.browserMeLevel,0,"Opposite stereo DC is silence in two complete channel windows")
        XCTAssertGreaterThan(owner.snapshot.meLevelTimestamp,0,"The assertion follows an actual complete meter window")
        try await owner.finish()
    }
    @MainActor func testNativeAndMixedRoutesStillAuthorizeNativeMicrophone() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at:root) }
        let owner = try OwnedBrowserCapture(parent:root,title:"Native",microphone:true,browser:false)
        let mic = PrivacyInput(), system = PrivacyInput()
        let inputs = CaptureInputLifecycle(capture:owner,originHostTime:mach_absolute_time(),microphone:{ mic },system:{ system },failure:{ _ in })
        try await inputs.start()
        XCTAssertTrue(owner.nativeMe); XCTAssertEqual(mic.authorizations,1); XCTAssertEqual(mic.starts,1)
        XCTAssertThrowsError(try owner.browserTrack(id:"local",label:"Me",kind:"local",sampleRate:8000,channels:1))
        try await inputs.stop(); try await owner.finish()
    }
    @MainActor func testLegacyBrowserStillAuthorizesNativeMeAndDoesNotAcceptSenderPCM() async throws {
        let root=try root();defer { try? FileManager.default.removeItem(at:root) }
        let owner=try OwnedBrowserCapture(parent:root,title:"Legacy browser",microphone:true,captureLocal:false)
        let mic=PrivacyInput(),system=PrivacyInput()
        let inputs=CaptureInputLifecycle(capture:owner,originHostTime:mach_absolute_time(),microphone:{mic},system:{system},failure:{_ in})
        try await inputs.start()
        XCTAssertTrue(owner.nativeMe)
        XCTAssertEqual(mic.authorizations,1);XCTAssertEqual(mic.starts,1)
        XCTAssertThrowsError(try owner.browserTrack(id:"unexpected-local",label:"Me",kind:"local",sampleRate:8000,channels:1))
        try await inputs.stop();try await owner.finish()
    }
}
