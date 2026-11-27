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
    var messages: [String] { lock.withLock { items } }
}

private func waitForGate(_ gate: DispatchSemaphore) -> Bool { gate.wait(timeout: .now() + 5) == .success }

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

private final class EventGatedFakeTap: SystemAudioTap, @unchecked Sendable {
    private let lock = NSLock()
    private var formatChangeHandler: (@Sendable () -> Void)?
    private var receiveHandler: (@Sendable (AVAudioPCMBuffer, UInt64) -> Void)?

    let startEntered: DispatchSemaphore?
    let releaseStart: DispatchSemaphore?
    let stopEntered: DispatchSemaphore?
    let releaseStop: DispatchSemaphore?
    let startError: Error?

    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var startRanOnMainThread = false
    private(set) var stopRanOnMainThread = false

    init(
        startEntered: DispatchSemaphore? = nil,
        releaseStart: DispatchSemaphore? = nil,
        stopEntered: DispatchSemaphore? = nil,
        releaseStop: DispatchSemaphore? = nil,
        startError: Error? = nil
    ) {
        self.startEntered = startEntered
        self.releaseStart = releaseStart
        self.stopEntered = stopEntered
        self.releaseStop = releaseStop
        self.startError = startError
    }

    func start(
        onFormatChange: @escaping @Sendable () -> Void,
        receive: @escaping @Sendable (AVAudioPCMBuffer, UInt64) -> Void
    ) throws {
        lock.withLock {
            startCount += 1
            startRanOnMainThread = Thread.isMainThread
            formatChangeHandler = onFormatChange
            receiveHandler = receive
        }
        startEntered?.signal()
        releaseStart?.wait()
        if let startError { throw startError }
    }

    func stop() {
        lock.withLock {
            stopCount += 1
            stopRanOnMainThread = Thread.isMainThread
            formatChangeHandler = nil
            receiveHandler = nil
        }
        stopEntered?.signal()
        releaseStop?.wait()
    }

    func triggerFormatChange() {
        let handler = lock.withLock { formatChangeHandler }
        handler?()
    }

    func emit(_ buffer: AVAudioPCMBuffer, hostTime: UInt64) {
        let handler = lock.withLock { receiveHandler }
        handler?(buffer, hostTime)
    }
}

private final class TapFactory: @unchecked Sendable {
    private let lock = NSLock()
    private var taps: [EventGatedFakeTap]
    private(set) var createdCount = 0

    init(_ taps: [EventGatedFakeTap]) { self.taps = taps }

    func next() -> any SystemAudioTap {
        lock.withLock {
            createdCount += 1
            return taps.removeFirst()
        }
    }
}

@Suite("Output tap off-main recovery")
struct OutputTapDriverTests {
    @Test func outputTapRestartRunsOffMainAndStopCancelsPendingRecreation() async throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("CassiniTapStop-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: parent) }
        let session = try RecordingSession(parent: parent, title: "Tap Stop", source: "macos")
        let failures = FailureRecorder()
        let sink = RecordingSink(session: session, originHostTime: AVAudioTime.hostTime(forSeconds: 100), targetSampleRate: 48_000) {
            failures.add($0)
        }

        let stopEntered = DispatchSemaphore(value: 0)
        let releaseStop = DispatchSemaphore(value: 0)
        let tap1 = EventGatedFakeTap(stopEntered: stopEntered, releaseStop: releaseStop)
        let tap2 = EventGatedFakeTap()
        let factory = TapFactory([tap1, tap2])
        let driver = OutputTapDriver(makeTap: { factory.next() })

        try driver.start(sink: sink, label: "Sound", changedMessage: "outputChanged") {
            failures.add($0)
        }
        #expect(factory.createdCount == 1)

        tap1.emit(try makeToneBuffer(sampleRate: 48_000, channels: 2, seconds: 0.1), hostTime: AVAudioTime.hostTime(forSeconds: 100))
        // Trigger format change while tap1.stop() is gated.
        tap1.triggerFormatChange()
        let entered = await Task.detached { waitForGate(stopEntered) }.value
        #expect(entered)
        #expect(!tap1.stopRanOnMainThread)

        // While tap1.stop() is still blocked on the dedicated serial executor,
        // @MainActor remains responsive and Stop returns immediately.
        let stopReturnedWhileBlocked = await MainActor.run { () -> Bool in
            driver.stop()
            return true
        }
        #expect(stopReturnedWhileBlocked)

        releaseStop.signal()
        await driver.drain()
        try sink.finish(problem: nil)

        #expect(factory.createdCount == 1, "Pending tap recreation must be cancelled after Stop")
        #expect(tap1.stopCount == 1)
        #expect(tap2.startCount == 0)
        #expect(failures.count == 0)
    }

    @Test func outputTapStopDuringSlowRecreationTearsDownNewTap() async throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("CassiniTapSlowStart-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: parent) }
        let session = try RecordingSession(parent: parent, title: "Tap Slow Start", source: "macos")
        let failures = FailureRecorder()
        let sink = RecordingSink(session: session, originHostTime: AVAudioTime.hostTime(forSeconds: 100), targetSampleRate: 48_000) {
            failures.add($0)
        }

        let startEntered = DispatchSemaphore(value: 0)
        let releaseStart = DispatchSemaphore(value: 0)
        let tap1 = EventGatedFakeTap()
        let tap2 = EventGatedFakeTap(startEntered: startEntered, releaseStart: releaseStart)
        let factory = TapFactory([tap1, tap2])
        let driver = OutputTapDriver(makeTap: { factory.next() })

        try driver.start(sink: sink, label: "Sound", changedMessage: "outputChanged") {
            failures.add($0)
        }

        tap1.emit(try makeToneBuffer(sampleRate: 48_000, channels: 2, seconds: 0.1), hostTime: AVAudioTime.hostTime(forSeconds: 100))
        tap1.triggerFormatChange()
        let entered = await Task.detached { waitForGate(startEntered) }.value
        #expect(entered)
        #expect(!tap2.startRanOnMainThread)

        await MainActor.run {
            driver.stop()
        }

        releaseStart.signal()
        await driver.drain()
        try sink.finish(problem: nil)

        #expect(factory.createdCount == 2)
        #expect(tap1.stopCount == 1)
        #expect(tap2.startCount == 1)
        #expect(tap2.stopCount == 1, "Newly started tap must be torn down immediately when Stop raced with start")
        #expect(failures.count == 0)
    }

    @Test func outputTapRecoversOffMainAcrossFormatChange() async throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("CassiniTapRecover-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: parent) }
        let session = try RecordingSession(parent: parent, title: "Tap Recover", source: "macos")
        let failures = FailureRecorder()
        let origin = AVAudioTime.hostTime(forSeconds: 100)
        let sink = RecordingSink(session: session, originHostTime: origin, targetSampleRate: 48_000) {
            failures.add($0)
        }

        let tap2Started = DispatchSemaphore(value: 0)
        let tap1 = EventGatedFakeTap()
        let tap2 = EventGatedFakeTap(startEntered: tap2Started)
        let factory = TapFactory([tap1, tap2])
        let driver = OutputTapDriver(makeTap: { factory.next() })

        try driver.start(sink: sink, label: "Sound", changedMessage: "outputChanged") {
            failures.add($0)
        }

        let before = try makeToneBuffer(sampleRate: 48_000, channels: 2, seconds: 0.2)
        tap1.emit(before, hostTime: origin)

        // Duplicate format-change callbacks from tap1 must coalesce to a single restart.
        tap1.triggerFormatChange()
        tap1.triggerFormatChange()
        let restarted = await Task.detached { waitForGate(tap2Started) }.value
        #expect(restarted)
        await driver.drain()

        #expect(factory.createdCount == 2)
        #expect(!tap1.stopRanOnMainThread)
        #expect(!tap2.startRanOnMainThread)

        let after = try makeToneBuffer(sampleRate: 24_000, channels: 1, seconds: 0.2)
        tap2.emit(after, hostTime: origin + AVAudioTime.hostTime(forSeconds: 0.2))

        driver.stop()
        await driver.drain()
        try sink.finish(problem: nil)

        #expect(failures.count == 0)
        let manifest = try RecordingLoader.load(directory: session.directory)
        let output = try #require(manifest.tracks.first { $0.id == "output" })
        #expect(output.sampleRate == 48_000)
        #expect(output.frames > 14_000)
    }

    @Test func outputTapRestartFailureReportsOnce() async throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("CassiniTapFail-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: parent) }
        let session = try RecordingSession(parent: parent, title: "Tap Fail", source: "macos")
        let failures = FailureRecorder()
        let sink = RecordingSink(session: session, originHostTime: AVAudioTime.hostTime(forSeconds: 100), targetSampleRate: 48_000) {
            failures.add($0)
        }

        let tap1 = EventGatedFakeTap()
        let tap2 = EventGatedFakeTap(startError: NSError(domain: "CassiniTest", code: 42))
        let factory = TapFactory([tap1, tap2])
        let driver = OutputTapDriver(makeTap: { factory.next() })

        try driver.start(sink: sink, label: "Sound", changedMessage: "outputChanged") {
            failures.add($0)
        }

        tap1.emit(try makeToneBuffer(sampleRate: 48_000, channels: 2, seconds: 0.1), hostTime: AVAudioTime.hostTime(forSeconds: 100))
        tap1.triggerFormatChange()
        await driver.drain()
        driver.stop()
        await driver.drain()
        try sink.finish(problem: nil)

        #expect(failures.messages == ["outputChanged"])
    }
}
