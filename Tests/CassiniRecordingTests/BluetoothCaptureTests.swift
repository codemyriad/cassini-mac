// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import Foundation
import Testing
@testable import CassiniRecording

private final class FakeMicrophoneEngine: MicrophoneAudioEngine {
    let token = NSObject()
    var notificationObject: AnyObject? { token }
    var format: AVAudioFormat
    var startError: Error?
    var startCount = 0
    var stopCount = 0
    var installCount = 0
    var removeCount = 0
    var tapBlock: (@Sendable (AVAudioPCMBuffer, UInt64) -> Void)?

    init(sampleRate: Double, channels: AVAudioChannelCount = 1) {
        self.format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels)!
    }

    func inputFormat() -> AVAudioFormat { format }

    func installTap(bufferSize: AVAudioFrameCount, format: AVAudioFormat, block: @escaping @Sendable (AVAudioPCMBuffer, UInt64) -> Void) {
        installCount += 1
        tapBlock = block
    }

    func removeTap() {
        removeCount += 1
        tapBlock = nil
    }

    func start() throws {
        startCount += 1
        if let startError { throw startError }
    }

    func stop() {
        stopCount += 1
    }

    func emitTone(seconds: Double, hostTime: UInt64, frequency: Double = 440) {
        let count = AVAudioFrameCount((format.sampleRate * seconds).rounded())
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count)!
        buffer.frameLength = count
        for c in 0..<Int(format.channelCount) {
            for f in 0..<Int(count) {
                buffer.floatChannelData![c][f] = 0.25 * Float(sin(2 * Double.pi * frequency * Double(f) / format.sampleRate))
            }
        }
        tapBlock?(buffer, hostTime)
    }
}

private final class FailureRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func add(_ message: String) { lock.withLock { items.append(message) } }
    var count: Int { lock.withLock { items.count } }
}

private func makeToneBuffer(sampleRate: Double, channels: AVAudioChannelCount = 1, seconds: Double, frequency: Double = 440) throws -> AVAudioPCMBuffer {
    let format = try #require(AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels))
    let count = AVAudioFrameCount((sampleRate * seconds).rounded())
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count))
    buffer.frameLength = count
    for c in 0..<Int(channels) {
        for f in 0..<Int(count) {
            buffer.floatChannelData![c][f] = 0.25 * Float(sin(2 * Double.pi * frequency * Double(f) / sampleRate))
        }
    }
    return buffer
}

@Suite struct BluetoothCaptureTests {
    @Test @MainActor func configurationChangeKeepsRecordingAndRestartFailureFiresOnce() throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("CassiniBTConfig-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: parent) }
        let session = try RecordingSession(parent: parent, title: "Bluetooth config test", source: "macos")
        let failures = FailureRecorder()
        let origin = AVAudioTime.hostTime(forSeconds: 100)
        let sink = RecordingSink(session: session, originHostTime: origin, targetSampleRate: 48_000) {
            failures.add($0)
        }
        let center = NotificationCenter()
        let engine = FakeMicrophoneEngine(sampleRate: 48_000, channels: 1)
        let driver = MicrophoneCaptureDriver(makeEngine: { engine }, notificationCenter: center)

        try driver.start(
            sink: sink,
            label: "Your microphone",
            missingError: { RecordingError.invalid("missing") },
            changedMessage: "mic changed",
            failure: { failures.add($0) }
        )

        // Emit 0.5 s at 48 kHz before configuration change.
        for i in 0..<5 {
            engine.emitTone(seconds: 0.1, hostTime: origin + AVAudioTime.hostTime(forSeconds: Double(i) * 0.1))
        }

        // Simulate Bluetooth earbuds switching from music mode (48 kHz) to headset mode (16 kHz).
        engine.format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        center.post(name: .AVAudioEngineConfigurationChange, object: engine.token)

        #expect(failures.count == 0)
        #expect(engine.removeCount == 1)
        #expect(engine.installCount == 2)
        #expect(engine.startCount == 2)

        // Buffers continue arriving after configuration change at 16 kHz.
        for i in 5..<10 {
            engine.emitTone(seconds: 0.1, hostTime: origin + AVAudioTime.hostTime(forSeconds: Double(i) * 0.1))
        }
        #expect(failures.count == 0)

        // Now simulate a restart failure: failure must be called exactly once.
        engine.startError = RecordingError.invalid("restart failed")
        center.post(name: .AVAudioEngineConfigurationChange, object: engine.token)
        center.post(name: .AVAudioEngineConfigurationChange, object: engine.token)
        #expect(failures.count == 1)

        driver.stop()
        try sink.finish(problem: nil)

        let manifest = try RecordingLoader.load(directory: session.directory)
        let mic = try #require(manifest.tracks.first { $0.id == "microphone" })
        #expect(mic.sampleRate == 48_000)
        let durationMs = Double(mic.frames) / Double(mic.sampleRate) * 1000
        #expect(abs(durationMs - 1000) <= 10)
    }

    @Test func inputChangeMidRecordingKeeps48kTrack() throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("CassiniBTInputChange-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: parent) }
        let session = try RecordingSession(parent: parent, title: "Input change test", source: "macos")
        let failures = FailureRecorder()
        let origin = AVAudioTime.hostTime(forSeconds: 200)
        let sink = RecordingSink(session: session, originHostTime: origin, targetSampleRate: 48_000) {
            failures.add($0)
        }

        // First 0.5 s at 48 kHz stereo, then switch mid-recording to 16 kHz mono.
        for i in 0..<10 {
            let buffer = try makeToneBuffer(sampleRate: 48_000, channels: 2, seconds: 0.05)
            sink.receive(buffer, hostTime: origin + AVAudioTime.hostTime(forSeconds: Double(i) * 0.05),
                         id: "microphone", label: "Mic", kind: "microphone")
        }
        for i in 10..<20 {
            let buffer = try makeToneBuffer(sampleRate: 16_000, channels: 1, seconds: 0.05)
            sink.receive(buffer, hostTime: origin + AVAudioTime.hostTime(forSeconds: Double(i) * 0.05),
                         id: "microphone", label: "Mic", kind: "microphone")
        }

        try sink.finish(problem: nil)
        #expect(failures.count == 0)

        let manifest = try RecordingLoader.load(directory: session.directory)
        let mic = try #require(manifest.tracks.first { $0.id == "microphone" })
        #expect(mic.sampleRate == 48_000)
        #expect(mic.channels == 2)
        let durationMs = Double(mic.frames) / Double(mic.sampleRate) * 1000
        #expect(abs(durationMs - 1000) <= 10)
    }

    @Test(arguments: [44_100.0, 24_000.0, 32_000.0, 96_000.0])
    func micTrackWrittenAt48kForNon48kDeviceRates(deviceRate: Double) throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("CassiniBT48k-\(Int(deviceRate))-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: parent) }
        let session = try RecordingSession(parent: parent, title: "Rate \(Int(deviceRate))", source: "macos")
        let failures = FailureRecorder()
        let origin = AVAudioTime.hostTime(forSeconds: 300)
        let sink = RecordingSink(session: session, originHostTime: origin, targetSampleRate: 48_000) {
            failures.add($0)
        }

        // Record 1.0 second in 20 ms callbacks.
        for i in 0..<50 {
            let buffer = try makeToneBuffer(sampleRate: deviceRate, channels: 1, seconds: 0.02)
            sink.receive(buffer, hostTime: origin + AVAudioTime.hostTime(forSeconds: Double(i) * 0.02),
                         id: "microphone", label: "Mic", kind: "microphone")
        }

        try sink.finish(problem: nil)
        #expect(failures.count == 0)

        let manifest = try RecordingLoader.load(directory: session.directory)
        let mic = try #require(manifest.tracks.first { $0.id == "microphone" })
        #expect(mic.sampleRate == 48_000)
        let durationMs = Double(mic.frames) / Double(mic.sampleRate) * 1000
        #expect(abs(durationMs - 1000) <= 10)
    }
}
