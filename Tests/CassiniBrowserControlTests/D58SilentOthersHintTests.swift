// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
import Foundation
import AVFoundation
import CassiniRecording
@testable import CassiniBrowserControl

/// D58.2 R2: a denied system-audio permission gives the tap digital silence, never an error. The
/// permission line shows after 5 s of silence while another app plays, and clears for good on the
/// first non-zero audio. Nothing is refused.
final class D58SilentOthersHintTests: XCTestCase {
    func testTheRuleNeedsFiveSecondsOfSilenceWhileAnotherAppPlays() {
        var rule = SilentOthersHint()
        XCTAssertFalse(rule.update(silent:true,playing:true,now:100))
        XCTAssertFalse(rule.update(silent:true,playing:true,now:104.9))
        XCTAssertTrue(rule.update(silent:true,playing:true,now:105),"5 s of digital silence while another app plays")
        // Nothing playing: a quiet Mac is no evidence, and the 5 s start again.
        XCTAssertFalse(rule.update(silent:true,playing:false,now:106))
        XCTAssertFalse(rule.update(silent:true,playing:true,now:107))
        XCTAssertFalse(rule.update(silent:true,playing:true,now:111.9))
        XCTAssertTrue(rule.update(silent:true,playing:true,now:112))
        // No system input (none, paused or failed): no hint.
        XCTAssertFalse(rule.update(silent:nil,playing:true,now:113))
        XCTAssertFalse(rule.update(silent:true,playing:true,now:114))
        XCTAssertTrue(rule.update(silent:true,playing:true,now:119))
        // The first non-zero audio clears it for the rest of the recording.
        XCTAssertFalse(rule.update(silent:false,playing:true,now:120))
        XCTAssertFalse(rule.update(silent:true,playing:true,now:130),"permission evidently works")
    }

    @MainActor func testTheLifecycleReportsOnlyDigitalSilenceUntilTheFirstNonzeroSample() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CassiniR2-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let owner = try OwnedBrowserCapture(parent:root,title:"Denied",microphone:true,browser:false)
        let origin = AVAudioTime.hostTime(forSeconds:ProcessInfo.processInfo.systemUptime)
        let system = SampleInput(origin:origin), microphone = SampleInput(origin:origin)
        let inputs = CaptureInputLifecycle(capture:owner,originHostTime:origin,microphone:{ microphone },system:{ system },failure:{ _ in })
        try await inputs.start()
        XCTAssertEqual(inputs.othersOnlyDigitalSilence,true,"armed, nothing heard yet")
        system.emit(value:0,atMs:100)                 // a denied tap: digital silence
        XCTAssertEqual(inputs.othersOnlyDigitalSilence,true)
        system.emit(value:0.25,atMs:200)              // real sound
        XCTAssertEqual(inputs.othersOnlyDigitalSilence,false)
        try await inputs.select(me:true,others:false,atMs:300)
        XCTAssertNil(inputs.othersOnlyDigitalSilence,"no system input once the others are off")
        try await inputs.stop(); try await owner.finish()
        XCTAssertNil(owner.snapshot.manifest.refusals,"an inferred denial is never a refusal")
    }
}

@MainActor private final class SampleInput: CaptureInput {
    let origin: UInt64
    var sink: RecordingSink?
    init(origin: UInt64) { self.origin = origin }
    func authorize() async throws {}
    func start(sink: RecordingSink, failure: @escaping @Sendable (String) -> Void) throws { self.sink = sink }
    func emit(value: Float, atMs: Double) {
        let format = AVAudioFormat(standardFormatWithSampleRate:8000,channels:1)!
        let buffer = AVAudioPCMBuffer(pcmFormat:format,frameCapacity:800)!
        buffer.frameLength = 800
        for index in 0..<800 { buffer.floatChannelData![0][index] = value }
        sink?.receive(buffer,hostTime:origin + AVAudioTime.hostTime(forSeconds:atMs/1000),id:"system",label:"system",kind:"system")
    }
    func stop() { sink = nil }
}
