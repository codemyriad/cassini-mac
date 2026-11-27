// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import Foundation
import XCTest
@testable import CassiniRecording

private final class MockMicrophoneAudioEngine: MicrophoneAudioEngine, @unchecked Sendable {
    var inputFormat: AVAudioFormat
    let token = NSObject()
    var notificationObject: AnyObject { token }
    private var tapHandler: (@Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void)?
    var startCount = 0
    var stopCount = 0
    var installTapCount = 0
    var removeTapCount = 0
    var throwOnStart: Error?

    init(sampleRate: Double = 48_000, channels: AVAudioChannelCount = 1) {
        self.inputFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels)!
    }

    func installInputTap(
        bufferSize: AVAudioFrameCount,
        format: AVAudioFormat,
        handler: @escaping @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void
    ) {
        installTapCount += 1
        tapHandler = handler
    }

    func removeInputTap() {
        removeTapCount += 1
        tapHandler = nil
    }

    func start() throws {
        startCount += 1
        if let error = throwOnStart {
            throw error
        }
    }

    func stop() {
        stopCount += 1
    }

    func emit(frames: AVAudioFrameCount, hostTime: UInt64, frequency: Double = 440) {
        guard let handler = tapHandler,
              let buffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: frames) else { return }
        buffer.frameLength = frames
        let rate = inputFormat.sampleRate
        for i in 0..<Int(frames) {
            buffer.floatChannelData![0][i] = 0.25 * Float(sin(2.0 * .pi * frequency * Double(i) / rate))
        }
        handler(buffer, AVAudioTime(hostTime: hostTime))
    }
}

private final class FailureRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [String] = []
    func record(_ message: String) {
        lock.lock()
        messages.append(message)
        lock.unlock()
    }
    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return messages.count
    }
    var all: [String] {
        lock.lock()
        defer { lock.unlock() }
        return messages
    }
}

private func makeToneBuffer(sampleRate: Double, channels: AVAudioChannelCount = 1, frames: AVAudioFrameCount, frequency: Double = 440, startFrame: Int = 0) throws -> AVAudioPCMBuffer {
    let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels))
    let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
    buffer.frameLength = frames
    for c in 0..<Int(channels) {
        for f in 0..<Int(frames) {
            buffer.floatChannelData![c][f] = 0.25 * Float(sin(2.0 * .pi * frequency * Double(startFrame + f) / sampleRate))
        }
    }
    return buffer
}

final class BluetoothAcceptanceTests: XCTestCase {
    private func expectStrictFailure(
        _ reason: String,
        matching marker: String,
        _ assertions: () -> Void
    ) {
        let options = XCTExpectedFailure.Options()
        options.isStrict = true
        options.issueMatcher = { issue in
            issue.type == .assertionFailure && issue.compactDescription.contains(marker)
        }
        XCTExpectFailure(reason, options: options, failingBlock: assertions)
    }

    @MainActor func testConfigurationChangeKeepsRecording() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("BluetoothConfigChange-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let session = try RecordingSession(parent: dir, title: "Bluetooth config test", source: "macos")
        let failures = FailureRecorder()
        let origin = AVAudioTime.hostTime(forSeconds: 100)
        let sink = RecordingSink(session: session, originHostTime: origin) { failures.record($0) }

        let center = NotificationCenter()
        let engine = MockMicrophoneAudioEngine(sampleRate: 48_000, channels: 1)
        let driver = MicrophoneInputDriver(makeEngine: { engine }, notificationCenter: center)

        try driver.start(sink: sink, micLabel: "Microphone") { failures.record($0) }
        defer { driver.stop() }

        // Prerequisite: initial buffer before configuration change must arrive.
        engine.emit(frames: 960, hostTime: origin)
        sink.flush()
        XCTAssertEqual(sink.status().frames["microphone"], 960)

        // Post AVAudioEngineConfigurationChange and await deterministic completion event.
        let firstHandled = expectation(description: "first configuration change handled")
        driver.onConfigurationChangeHandled = { firstHandled.fulfill() }
        center.post(name: .AVAudioEngineConfigurationChange, object: engine.notificationObject)
        await fulfillment(of: [firstHandled], timeout: 5.0)
        let failuresAfterFirstChange = failures.all

        // Deliver another buffer after the configuration change.
        let afterHost = origin + AVAudioTime.hostTime(forSeconds: 0.02)
        engine.emit(frames: 960, hostTime: afterHost)
        sink.flush()
        let framesAfterFirstChange = sink.status().frames["microphone"]

        // If restart throws on a subsequent configuration change, failure must be called exactly once.
        let secondHandled = expectation(description: "second configuration change handled")
        driver.onConfigurationChangeHandled = { secondHandled.fulfill() }
        engine.throwOnStart = RecordingError.invalid("Simulated engine restart failure")
        center.post(name: .AVAudioEngineConfigurationChange, object: engine.notificationObject)
        await fulfillment(of: [secondHandled], timeout: 5.0)
        let failuresAfterSecondChange = failures.all

        driver.stop()
        try? sink.finish(problem: nil)

        expectStrictFailure("D-1196 item 1", matching: "[D-1196-item1]") {
            XCTAssertEqual(failuresAfterFirstChange.count, 0, "[D-1196-item1] Configuration change must not fail recording: \(failuresAfterFirstChange)")
            XCTAssertEqual(framesAfterFirstChange, 1920, "[D-1196-item1] Buffers must keep arriving after configuration change")
            XCTAssertEqual(failuresAfterSecondChange.count, 1, "[D-1196-item1] Restart failure must invoke failure callback exactly once: \(failuresAfterSecondChange)")
        }
    }

    func testInputChangeMidRecording() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("BluetoothRateSwitch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let session = try RecordingSession(parent: dir, title: "Rate switch test", source: "macos")
        let failures = FailureRecorder()
        let origin = AVAudioTime.hostTime(forSeconds: 100)
        let sink = RecordingSink(session: session, originHostTime: origin) { failures.record($0) }

        // First 0.5 s at 48 000 Hz (25 x 20 ms chunks = 24 000 frames).
        for chunk in 0..<25 {
            let host = origin + AVAudioTime.hostTime(forSeconds: Double(chunk) * 0.02)
            let buf = try makeToneBuffer(sampleRate: 48_000, frames: 960, startFrame: chunk * 960)
            sink.receive(buf, hostTime: host, id: "microphone", label: "Microphone", kind: "microphone")
        }
        // Switch mid-recording to 16 000 Hz (25 x 20 ms chunks = 8 000 frames).
        for chunk in 0..<25 {
            let host = origin + AVAudioTime.hostTime(forSeconds: 0.5 + Double(chunk) * 0.02)
            let buf = try makeToneBuffer(sampleRate: 16_000, frames: 320, startFrame: chunk * 320)
            sink.receive(buf, hostTime: host, id: "microphone", label: "Microphone", kind: "microphone")
        }
        enum FinishOutcome {
            case rejectedFormatChange(String)
            case finished(sampleRate: Int, durationMs: Double)
        }

        let outcome: FinishOutcome
        do {
            try sink.finish(problem: nil)
            let manifestData = try Data(contentsOf: session.directory.appendingPathComponent("session.json"))
            let manifest = try RecordingLoader.decode(manifestData)
            let micTrack = try XCTUnwrap(manifest.tracks.first { $0.id == "microphone" })
            let wavURL = session.directory.appendingPathComponent(micTrack.file)
            let wavSize = try FileManager.default.attributesOfItem(atPath: wavURL.path)[.size] as? Int ?? 0
            let pcmFrames = max(0, wavSize - 44) / (micTrack.channels * 2)
            let durationMs = Double(pcmFrames) * 1000.0 / Double(micTrack.sampleRate)
            outcome = .finished(sampleRate: micTrack.sampleRate, durationMs: durationMs)
        } catch let RecordingError.invalid(message) {
            outcome = .rejectedFormatChange(message)
        }

        expectStrictFailure("D-1196 item 2", matching: "[D-1196-item2]") {
            XCTAssertEqual(failures.count, 0, "[D-1196-item2] Mid-recording rate change must not fail: \(failures.all)")
            switch outcome {
            case let .rejectedFormatChange(message):
                XCTFail("[D-1196-item2] sink.finish rejected mid-recording rate change: \(message)")
            case let .finished(sampleRate, durationMs):
                XCTAssertEqual(sampleRate, 48_000, "[D-1196-item2] Saved mic track must stay at 48 kHz")
                XCTAssertEqual(durationMs, 1000.0, accuracy: 10.0, "[D-1196-item2] Saved mic track duration must match 1000 ms ±10 ms")
            }
        }
    }

    func testMicTrackWrittenAt48k() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Bluetooth44kTo48k-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let session = try RecordingSession(parent: dir, title: "44.1 kHz mic test", source: "macos")
        let failures = FailureRecorder()
        let origin = AVAudioTime.hostTime(forSeconds: 100)
        let sink = RecordingSink(session: session, originHostTime: origin) { failures.record($0) }

        // Feed 1.0 s at 44 100 Hz (100 x 10 ms chunks = 44 100 frames).
        for chunk in 0..<100 {
            let host = origin + AVAudioTime.hostTime(forSeconds: Double(chunk) * 0.01)
            let buf = try makeToneBuffer(sampleRate: 44_100, frames: 441, startFrame: chunk * 441)
            sink.receive(buf, hostTime: host, id: "microphone", label: "Microphone", kind: "microphone")
        }
        try sink.finish(problem: nil)

        let manifestData = try Data(contentsOf: session.directory.appendingPathComponent("session.json"))
        let manifest = try RecordingLoader.decode(manifestData)
        let micTrack = try XCTUnwrap(manifest.tracks.first { $0.id == "microphone" })
        let wavURL = session.directory.appendingPathComponent(micTrack.file)
        let wavSize = try FileManager.default.attributesOfItem(atPath: wavURL.path)[.size] as? Int ?? 0
        let pcmFrames = max(0, wavSize - 44) / (micTrack.channels * 2)
        let durationMs = Double(pcmFrames) * 1000.0 / Double(micTrack.sampleRate)

        expectStrictFailure("D-1196 item 3", matching: "[D-1196-item3]") {
            XCTAssertEqual(failures.count, 0, "[D-1196-item3] 44.1 kHz mic capture must not fail: \(failures.all)")
            XCTAssertEqual(micTrack.sampleRate, 48_000, "[D-1196-item3] Mic track in session.json must be written at 48 000 Hz")
            XCTAssertEqual(durationMs, 1000.0, accuracy: 10.0, "[D-1196-item3] Mic track length must match recorded time ±10 ms")
        }
    }
}
