// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
import Foundation
import AVFoundation
import CassiniRecording
@testable import CassiniBrowserControl

@MainActor private final class GeneratedInput: CaptureInput {
    let kind: String
    var authorized = 0, starts = 0, stops = 0
    var permission: CheckedContinuation<Void,Error>?
    var holdPermission = false, denied = false
    var sink: RecordingSink?
    var failure: (@Sendable (String) -> Void)?
    var firstAt: Double = 0
    let origin: UInt64
    init(_ kind: String, origin: UInt64) { self.kind = kind; self.origin = origin }
    func authorize() async throws {
        authorized += 1
        if denied { throw CocoaError(.fileReadNoPermission) }
        if holdPermission { try await withCheckedThrowingContinuation { permission = $0 } }
    }
    func start(sink: RecordingSink, failure: @escaping @Sendable (String) -> Void) throws { self.sink = sink; self.failure = failure; starts += 1; emit(at:firstAt) }
    func emit(at seconds: Double) {
        let format = AVAudioFormat(standardFormatWithSampleRate:8000,channels:1)!
        let buffer = AVAudioPCMBuffer(pcmFormat:format,frameCapacity:800)!
        buffer.frameLength = 800
        for index in 0..<800 { buffer.floatChannelData![0][index] = 0.25 }
        sink?.receive(buffer,hostTime:origin + AVAudioTime.hostTime(forSeconds:seconds),id:kind,label:kind,kind:kind)
    }
    func stop() { stops += 1; sink = nil }
}
final class InputLifecycleTests: XCTestCase, @unchecked Sendable {
    @MainActor func testTurningMeOffAfterACountedGapStillAppliesSelection() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let owner = try OwnedBrowserCapture(parent:root,title:"Turn off after gap",microphone:true)
        let origin = AVAudioTime.hostTime(forSeconds:ProcessInfo.processInfo.systemUptime)
        let mic = GeneratedInput("microphone",origin:origin), system = GeneratedInput("system",origin:origin)
        let inputs = CaptureInputLifecycle(capture:owner,originHostTime:origin,microphone:{ mic },system:{ system },failure:{ _ in })
        try await inputs.start()
        mic.emit(at:1.1)
        do { try await inputs.select(me:false,others:true,atMs:1200) }
        catch { try? await inputs.stop(); try? await owner.finish(); throw error }
        XCTAssertFalse(owner.snapshot.me); XCTAssertTrue(owner.snapshot.others)
        XCTAssertEqual(owner.snapshot.manifest.tracks.first?.gapFrames,8000)
        XCTAssertEqual(owner.snapshot.manifest.tracks.first?.ended,true)
        try await inputs.stop(); try await owner.finish()
        XCTAssertEqual(owner.snapshot.manifest.problemKind,"gap")
    }
    @MainActor func testRetryMePreservesSystemAndIgnoresFailureFromPreviousMic() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let owner = try OwnedBrowserCapture(parent:root,title:"Retry only Me",microphone:true,browser:false)
        let origin = AVAudioTime.hostTime(forSeconds:ProcessInfo.processInfo.systemUptime)
        let mic = GeneratedInput("microphone",origin:origin), system = GeneratedInput("system",origin:origin)
        let inputs = CaptureInputLifecycle(capture:owner,originHostTime:origin,microphone:{ mic },system:{ system },failure:{ _ in })
        mic.denied = true
        do { try await inputs.start(); XCTFail("Denied microphone must fail") } catch {}
        XCTAssertEqual(system.starts,1)
        mic.denied = false
        try await inputs.retry(.me)
        XCTAssertEqual(mic.starts,1); XCTAssertEqual(system.starts,1); XCTAssertEqual(system.stops,0)
        let previousFailure = mic.failure
        try await inputs.select(me:false,others:true,atMs:100)
        mic.firstAt = 0.3
        try await inputs.select(me:true,others:true,atMs:200)
        previousFailure?("Late callback from the stopped microphone")
        try await Task.sleep(for:.milliseconds(50))
        XCTAssertFalse(inputs.failedSides.contains(.me)); XCTAssertEqual(mic.stops,1)
        system.emit(at:0.1)
        try await inputs.stop(); try await owner.finish()
        XCTAssertEqual(owner.snapshot.manifest.tracks.first { $0.kind == "system" }?.frames,1600)
        XCTAssertEqual(owner.snapshot.manifest.state,"completed")
    }
    @MainActor func testLateMicFailureStopsOnlyItsInputAndRetainsSystemSamples() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let owner = try OwnedBrowserCapture(parent:root,title:"One input lost",microphone:true,browser:false)
        let origin = AVAudioTime.hostTime(forSeconds:ProcessInfo.processInfo.systemUptime)
        let mic = GeneratedInput("microphone",origin:origin), system = GeneratedInput("system",origin:origin)
        let inputs = CaptureInputLifecycle(capture:owner,originHostTime:origin,microphone:{ mic },system:{ system },failure:{ _ in })
        try await inputs.start()
        mic.failure?("Generated microphone failure")
        let deadline = Date().addingTimeInterval(3)
        while !inputs.failedSides.contains(.me) && Date() < deadline { try await Task.sleep(for:.milliseconds(5)) }
        XCTAssertTrue(inputs.failedSides.contains(.me)); XCTAssertEqual(mic.stops,1)
        XCTAssertEqual(system.stops,0)
        system.emit(at:0.1)
        try await inputs.stop(); try await owner.finish()
        XCTAssertEqual(owner.snapshot.manifest.tracks.first { $0.kind == "system" }?.frames,1600)
        XCTAssertEqual(owner.snapshot.manifest.state,"interrupted")
    }
    @MainActor func testDeniedMicrophoneDoesNotPreventSystemFallbackOrKeepRequestingPermission() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let owner = try OwnedBrowserCapture(parent:root,title:"Partial permission",microphone:true)
        let origin = AVAudioTime.hostTime(forSeconds:ProcessInfo.processInfo.systemUptime)
        let mic = GeneratedInput("microphone",origin:origin), system = GeneratedInput("system",origin:origin)
        mic.denied = true
        let inputs = CaptureInputLifecycle(capture:owner,originHostTime:origin,microphone:{ mic },system:{ system },failure:{ _ in })
        do { try await inputs.start(); XCTFail("Mic permission must fail") } catch {}
        try owner.browserLost(atMs:0)
        try await inputs.update(); try await inputs.update()
        XCTAssertEqual(mic.authorized,1); XCTAssertEqual(system.starts,1)
        XCTAssertEqual(inputs.failedSides,[.me])
        try await inputs.stop(); try await owner.finish()
        XCTAssertEqual(owner.snapshot.manifest.tracks.map(\.kind),["system"])
    }
    @MainActor func testTwoMeetingsOwnTheirNativeInputsAndOnlyTheLostOneStartsSystem() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let a = try OwnedBrowserCapture(parent:root,title:"One",microphone:true)
        let b = try OwnedBrowserCapture(parent:root,title:"Two",microphone:true)
        let origin = AVAudioTime.hostTime(forSeconds:ProcessInfo.processInfo.systemUptime)
        let micA = GeneratedInput("microphone",origin:origin), micB = GeneratedInput("microphone",origin:origin)
        let systemA = GeneratedInput("system",origin:origin), systemB = GeneratedInput("system",origin:origin)
        let first = CaptureInputLifecycle(capture:a,originHostTime:origin,microphone:{ micA },system:{ systemA },failure:{ _ in })
        let second = CaptureInputLifecycle(capture:b,originHostTime:origin,microphone:{ micB },system:{ systemB },failure:{ _ in })
        try await first.start(); try await second.start()
        try a.browserLost(atMs:0); try await first.update()
        XCTAssertEqual(systemA.starts,1); XCTAssertEqual(systemB.starts,0)
        try await first.stop(); try await a.finish()
        XCTAssertEqual(micA.stops,1); XCTAssertEqual(micB.stops,0)
        micB.emit(at:0.1)
        try await second.stop(); try await b.finish()
        XCTAssertEqual(b.snapshot.manifest.tracks.count,1)
        XCTAssertEqual(b.snapshot.manifest.tracks[0].frames,1600)
        XCTAssertEqual(a.snapshot.manifest.tracks.map(\.kind),["microphone","system"])
    }
    @MainActor func testOthersOnlyDoesNotAuthorizeMicAndLossStartsOnlySystemInItsOwnFolder() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let owner = try OwnedBrowserCapture(parent:root,title:"Only others",microphone:false)
        let origin = AVAudioTime.hostTime(forSeconds:ProcessInfo.processInfo.systemUptime)
        let mic = GeneratedInput("microphone",origin:origin), system = GeneratedInput("system",origin:origin)
        let inputs = CaptureInputLifecycle(capture:owner,originHostTime:origin,microphone:{ mic },system:{ system },failure:{ _ in })
        try await inputs.start(); XCTAssertEqual(mic.authorized,0); XCTAssertEqual(system.starts,0)
        try owner.browserLost(atMs:0)
        try await inputs.update(); try await inputs.update()
        XCTAssertEqual(mic.authorized,0); XCTAssertEqual(system.starts,1)
        try await inputs.stop(); try await owner.finish()
        XCTAssertEqual(owner.snapshot.manifest.tracks.map(\.kind),["system"])
        XCTAssertEqual(owner.snapshot.manifest.tracks[0].frames,800)
        XCTAssertEqual(owner.snapshot.manifest.events?.last?.source,"system")
    }
    @MainActor func testMeOffOnDrainsAndCreatesAFreshMicSpanWithoutStoppingBrowser() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let owner = try OwnedBrowserCapture(parent:root,title:"Me toggle",microphone:true)
        let origin = AVAudioTime.hostTime(forSeconds:ProcessInfo.processInfo.systemUptime)
        var microphones: [GeneratedInput] = []
        let system = GeneratedInput("system",origin:origin)
        let inputs = CaptureInputLifecycle(capture:owner,originHostTime:origin,microphone:{ let mic = GeneratedInput("microphone",origin:origin); mic.firstAt = Double(microphones.count)*0.3; microphones.append(mic); return mic },system:{ system },failure:{ _ in })
        try await inputs.start()
        try owner.browserTrack(id:"r",label:"Other",kind:"remote",sampleRate:8000,channels:1)
        try await inputs.select(me:false,others:true,atMs:100)
        XCTAssertEqual(microphones[0].stops,1)
        XCTAssertEqual(owner.snapshot.manifest.tracks.first { $0.kind == "microphone" }?.ended,true)
        microphones[0].emit(at:0.1) // Stopped driver has no route to a sink.
        try owner.browserAudio(id:"r",sequence:0,offsetMs:100,pcm:Data(repeating:0,count:1600))
        try await inputs.select(me:true,others:true,atMs:200)
        XCTAssertEqual(microphones.count,2); XCTAssertEqual(system.starts,0)
        try await inputs.stop(); try await owner.finish()
        let tracks = owner.snapshot.manifest.tracks.filter { $0.kind == "microphone" }
        XCTAssertEqual(tracks.count,2); XCTAssertNotEqual(tracks[0].id,tracks[1].id)
        XCTAssertEqual(tracks.map(\.frames),[800,800])
        XCTAssertEqual(owner.snapshot.manifest.tracks.first { $0.kind == "remote" }?.frames,800)
    }
    @MainActor func testDeniedMeSelectionLeavesTheWorkingSelectionAndBrowserUntouched() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let owner = try OwnedBrowserCapture(parent:root,title:"Denied mic",microphone:false)
        let origin = AVAudioTime.hostTime(forSeconds:ProcessInfo.processInfo.systemUptime)
        let mic = GeneratedInput("microphone",origin:origin), system = GeneratedInput("system",origin:origin)
        mic.denied = true
        let inputs = CaptureInputLifecycle(capture:owner,originHostTime:origin,microphone:{ mic },system:{ system },failure:{ _ in })
        do { try await inputs.select(me:true,others:false,atMs:0); XCTFail("Denied permission must fail") } catch {}
        XCTAssertFalse(owner.snapshot.me); XCTAssertTrue(owner.snapshot.others); XCTAssertTrue(owner.snapshot.browserAlive)
        XCTAssertEqual(owner.snapshot.manifest.events?.count,2); XCTAssertEqual(mic.starts,0)
        try await inputs.stop(); try await owner.finish()
    }
    @MainActor func testStopDuringPermissionWaitPreventsALateMicrophoneStart() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let owner = try OwnedBrowserCapture(parent:root,title:"Pending permission",microphone:true,browser:false)
        let origin = AVAudioTime.hostTime(forSeconds:ProcessInfo.processInfo.systemUptime)
        let mic = GeneratedInput("microphone",origin:origin), system = GeneratedInput("system",origin:origin)
        mic.holdPermission = true
        let inputs = CaptureInputLifecycle(capture:owner,originHostTime:origin,microphone:{ mic },system:{ system },failure:{ _ in })
        let starting = Task { try await inputs.start() }
        let deadline = Date().addingTimeInterval(2)
        while mic.permission == nil && Date() < deadline { await Task.yield() }
        guard mic.permission != nil else { XCTFail("Permission request did not start"); throw BrowserIPCError.timeout }
        let systemStartedBeforeReply = system.starts
        var stopped = false
        let stopping = Task { try await inputs.stop(); stopped = true }
        let stopDeadline = Date().addingTimeInterval(2)
        while !stopped && Date() < stopDeadline { try await Task.sleep(for:.milliseconds(5)) }
        let stoppedBeforeReply = stopped
        mic.permission?.resume(); mic.permission = nil
        try await starting.value; try await stopping.value; try await owner.finish()
        XCTAssertTrue(stoppedBeforeReply,"Stop must not require an answer to the permission prompt")
        XCTAssertEqual(systemStartedBeforeReply,1,"Available Others must not wait for microphone permission")
        XCTAssertEqual(mic.starts,0); XCTAssertEqual(system.stops,1)
        XCTAssertEqual(owner.snapshot.manifest.tracks.map(\.kind),["system"])
    }
}
