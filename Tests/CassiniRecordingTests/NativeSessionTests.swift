import AVFoundation
import Foundation
import Testing
@testable import CassiniRecording

private func nativeBuffer(rate: Double, frames: UInt32) throws -> AVAudioPCMBuffer {
    let format = try #require(AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1))
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
    buffer.frameLength = frames
    for i in 0..<Int(frames) { buffer.floatChannelData![0][i] = 0.25 }
    return buffer
}
private final class StalledSession: RecordingSinkWriter, @unchecked Sendable {
    let session: RecordingSession
    let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
    var stall = true
    var finishDelayMs = 0
    init(_ session: RecordingSession) { self.session = session }
    var recordingProblem: String? { session.recordingProblem }
    func addTrack(id: String, label: String, kind: String, sampleRate: Int, channels: Int) throws { try session.addTrack(id: id, label: label, kind: kind, sampleRate: sampleRate, channels: channels) }
    func appendNative(id: String, pcm: Data, offsetMs: Double) throws {
        if stall { stall = false; entered.signal(); release.wait() }
        try session.appendNative(id: id, pcm: pcm, offsetMs: offsetMs)
    }
    func finish(problem: String?) throws { try session.finish(problem: problem) }
    func finish(problem: String?, kind: String?) throws {
        if finishDelayMs > 0 { Thread.sleep(forTimeInterval: Double(finishDelayMs) / 1000) }
        try session.finish(problem: problem, kind: kind)
    }
    func reportLoss(id: String, droppedFrames: UInt64, gapFrames: UInt64) { session.reportLoss(id: id, droppedFrames: droppedFrames, gapFrames: gapFrames) }
}

@Suite struct NativeRecordingSessionTests {
    @Test(arguments: [0.99995, 1.00005]) func tenHoursSmoothDriftIsNotAHostTimeJump(scalar: Double) {
        var previous = 0.0
        var gaps: UInt64 = 0
        for index in 1...4500 {
            let host = Double(index) * 8000 * scalar
            gaps += NativeSourceTimeline.missingFrames(sampleRate: 8000, hostOffsetMs: host, previousHostMs: previous, previousInputFrames: 64000)
            previous = host
        }
        #expect(gaps == 0)
        #expect(NativeSourceTimeline.missingFrames(sampleRate: 8000, hostOffsetMs: 1010, previousHostMs: 0, previousInputFrames: 80) == 8000)
    }

    @Test(arguments: [0.99995, 1.00005]) func tenMinuteRealWAVAt44100With512FrameBuffers(scalar: Double) throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: parent) }
        let session = try RecordingSession(parent: parent, title: "Native drift", source: "macos")
        let sink = RecordingSink(session: session, originHostTime: 1) { _ in }
        let buffer = try nativeBuffer(rate: 44100, frames: 512)
        let target = 44100 * 600
        var input = 0, batches = 0
        while input < target {
            buffer.frameLength = UInt32(min(512, target - input))
            sink.receive(buffer, hostTime: 1 + AVAudioTime.hostTime(forSeconds: Double(input) / 44100 * scalar), id: "mic", label: "Microphone", kind: "microphone")
            input += Int(buffer.frameLength); batches += 1
            if batches % 256 == 0 { sink.flush() }
        }
        try sink.finish(problem: nil)
        let track = try #require(session.manifest.tracks.first)
        let file = try FileHandle(forReadingFrom: session.directory.appendingPathComponent(track.file)); defer { try? file.close() }
        let rawHeader = try file.read(upToCount: 44)
        let header = try #require(rawHeader)
        let dataBytes = header.withUnsafeBytes { Int($0.loadUnaligned(fromByteOffset: 40, as: UInt32.self).littleEndian) }
        #expect(dataBytes == target * 2)
        #expect(try file.seekToEnd() == UInt64(44 + target * 2))
        #expect(track.frames == UInt64(target))
        #expect(session.manifest.state == "completed")
        #expect(session.manifest.problem == nil)
        #expect(sink.status().gapMs == 0)
        #expect(sink.status().droppedMs == 0)
    }

    @Test func resumedInputPreservesTenSecondGapInRealWAV() throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: parent) }
        let session = try RecordingSession(parent: parent, title: "Native gap", source: "macos")
        let sink = RecordingSink(session: session, originHostTime: 1) { _ in }
        let buffer = try nativeBuffer(rate: 8000, frames: 80)
        for index in 0..<10 {
            sink.receive(buffer, hostTime: 1 + AVAudioTime.hostTime(forSeconds: Double(index) * 0.01 + (index >= 5 ? 10 : 0)), id: "mic", label: "Microphone", kind: "microphone")
            sink.flush()
        }
        #expect(abs(sink.status().gapMs - 10000) < 0.1)
        #expect(throws: (any Error).self) { try sink.finish(problem: nil) }
        let track = try #require(session.manifest.tracks.first)
        let wav = try Data(contentsOf: session.directory.appendingPathComponent(track.file))
        #expect(track.frames == 80800)
        #expect(track.gapFrames == 80000)
        #expect(wav[844..<160844].allSatisfy { $0 == 0 })
        #expect(wav[160844...].contains { $0 != 0 })
        #expect(session.manifest.problemKind == "gap")
    }

    @Test func missingInputStampDoesNotTurnDeliveryTimeIntoACountedGap() throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: parent) }
        let session = try RecordingSession(parent: parent, title: "Missing host stamp", source: "macos")
        let origin = AVAudioTime.hostTime(forSeconds: ProcessInfo.processInfo.systemUptime)
        let sink = RecordingSink(session: session, originHostTime: origin) { _ in }
        let buffer = try nativeBuffer(rate: 8000, frames: 80)
        for host in [origin, 0, origin + AVAudioTime.hostTime(forSeconds: 10)] {
            sink.receive(buffer, hostTime: host, id: "mic", label: "Microphone", kind: "microphone")
            sink.flush()
        }
        try sink.finish(problem: nil)
        #expect(session.manifest.tracks[0].frames == 240)
        #expect(sink.status().gapMs == 0)
    }

    @Test func realSessionStallInsertsSubToleranceSilenceAndReportsIO() throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: parent) }
        let session = try RecordingSession(parent: parent, title: "Native stall", source: "macos")
        let writer = StalledSession(session)
        let sink = RecordingSink(session: writer, capacitySeconds: 0.01, originHostTime: 1) { _ in }
        let buffer = try nativeBuffer(rate: 8000, frames: 80)
        sink.receive(buffer, hostTime: 1, id: "mic", label: "Microphone", kind: "microphone")
        #expect(writer.entered.wait(timeout: .now() + 2) == .success)
        sink.receive(buffer, hostTime: 1 + AVAudioTime.hostTime(forSeconds: 0.01), id: "mic", label: "Microphone", kind: "microphone")
        sink.receive(buffer, hostTime: 1, id: "output", label: "Output", kind: "system")
        #expect(sink.status().frames["output"] == 80)
        writer.release.signal(); sink.flush()
        sink.receive(buffer, hostTime: 1 + AVAudioTime.hostTime(forSeconds: 0.02), id: "mic", label: "Microphone", kind: "microphone")
        #expect(throws: (any Error).self) { try sink.finish(problem: nil) }
        let track = try #require(session.manifest.tracks.first)
        let wav = try Data(contentsOf: session.directory.appendingPathComponent(track.file))
        #expect(track.frames == 240)
        #expect(track.droppedFrames == 80)
        #expect(wav[204..<364].allSatisfy { $0 == 0 })
        #expect(wav[364...].contains { $0 != 0 })
        #expect(session.manifest.problemKind == "io")
    }
    @Test @MainActor func asyncFinalizationKeepsMainActorResponsive() async throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: parent) }
        let session = try RecordingSession(parent: parent, title: "Async save", source: "macos")
        let writer = StalledSession(session)
        writer.stall = false; writer.finishDelayMs = 200
        let sink = RecordingSink(session: writer, originHostTime: 1) { _ in }
        sink.receive(try nativeBuffer(rate: 8000, frames: 80), hostTime: 1, id: "mic", label: "Mic", kind: "microphone")
        var finished = false
        let completion = Task { try await sink.finishAsync(problem: nil); finished = true }
        try await Task.sleep(for: .milliseconds(30))
        #expect(!finished, "A slow final writer must not block this MainActor continuation")
        try await completion.value
        #expect(finished)
    }

}
