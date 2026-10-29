// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import Foundation
import Testing
@testable import CassiniRecording

private final class SinkWriter: RecordingSinkWriter, @unchecked Sendable {
    var chunks: [(String, Data, Double)] = []
    var formats: [String: (Int, Int)] = [:]
    var recordingProblem: String?
    var finishes = 0
    var reject = false
    var retainPCM = true
    var bytes = 0
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    var stall = false
    func addTrack(id: String, label: String, kind: String, sampleRate: Int, channels: Int) throws {
        formats[id] = (sampleRate, channels)
    }
    func appendNative(id: String, pcm: Data, offsetMs: Double) throws {
        if stall { stall = false; entered.signal(); release.wait() }
        if reject { throw RecordingError.invalid("Injected writer failure") }
        bytes += pcm.count
        chunks.append((id, retainPCM ? pcm : Data(), offsetMs))
    }
    func finish(problem: String?) throws { finishes += 1; recordingProblem = problem }
}
private final class Failures: @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [String] = []
    func add(_ message: String) { lock.lock(); messages.append(message); lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return messages.count }
}
private func buffer(channels: UInt32, interleaved: Bool = false, frames: UInt32 = 4) throws -> AVAudioPCMBuffer {
    let layout = try #require(AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | channels))
    let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 8000, interleaved: interleaved, channelLayout: layout))
    let result = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
    result.frameLength = frames
    for c in 0..<Int(channels) {
        for f in 0..<Int(frames) {
            result.floatChannelData![interleaved ? 0 : c][interleaved ? f * Int(channels) + c : f] = 0
        }
    }
    return result
}

@Suite struct RecordingSinkTests {
    @Test func dcOffsetIsSilentWithoutChangingRecordedSamples() throws {
        let input = try buffer(channels:1,frames:800)
        for i in 0..<800 { input.floatChannelData![0][i] = -2060.0/32768 }
        let writer = SinkWriter(), failures = Failures()
        let sink = RecordingSink(session:writer,originHostTime:1) { failures.add($0) }
        sink.receive(input,hostTime:1,id:"mic",label:"Mic",kind:"microphone")
        try sink.finish(problem:nil)
        #expect(sink.status().levels["mic"] == 0)
        #expect(writer.chunks[0].1.withUnsafeBytes { $0.bindMemory(to:Int16.self).allSatisfy { Int16(littleEndian:$0) == -2060 } })
    }
    @Test(arguments:[false,true]) func acPeakCentresChannelsAndCarriesAcrossCallbacks(interleaved: Bool) throws {
        let writer = SinkWriter(), failures = Failures()
        let sink = RecordingSink(session:writer,originHostTime:1) { failures.add($0) }
        for (index,value) in [Float(0.1),0.2].enumerated() {
            let frames: UInt32 = index == 0 ? 320 : 480
            let input = try buffer(channels:2,interleaved:interleaved,frames:frames)
            for i in 0..<Int(frames) {
                for channel in 0..<2 { input.floatChannelData![interleaved ? 0 : channel][interleaved ? i*2+channel : i] = value + (channel == 0 ? -0.3 : 0.5) }
            }
            sink.receive(input,hostTime:1+AVAudioTime.hostTime(forSeconds:index == 0 ? 0 : 0.04),id:"mic",label:"Mic",kind:"microphone")
        }
        try sink.finish(problem:nil)
        let peak = try #require(sink.status().levels["mic"])
        #expect(abs(peak-0.06) < 0.000001)
        #expect(writer.bytes == 800*2*2)
    }
    @Test(arguments: [false, true]) func quantizationAndMultichannelSelection(interleaved: Bool) throws {
        for channels: UInt32 in [1, 2, 4] {
            let input = try buffer(channels: channels, interleaved: interleaved, frames: 6)
            let values: [Float] = [-2, -0.5, .nan, .infinity, 0.5, 2]
            for c in 0..<Int(channels) {
                for f in 0..<6 {
                    input.floatChannelData![interleaved ? 0 : c][interleaved ? f * Int(channels) + c : f] = c < 2 ? values[f] : 0.9
                }
            }
            let writer = SinkWriter(), failures = Failures()
            let sink = RecordingSink(session: writer, originHostTime: 1) { failures.add($0) }
            sink.receive(input, hostTime: 1, id: "x", label: "Input", kind: "microphone")
            try sink.finish(problem: nil)
            let count = min(2, Int(channels))
            let expected: [Int16] = [-32767, -16384, 0, 0, 16384, 32767].flatMap { Array(repeating: Int16($0), count: count) }
            #expect(writer.chunks[0].1.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) } == expected)
            #expect(writer.formats["x"]?.1 == count)
            #expect(failures.count == 0)
            #expect(sink.status().warnings.isEmpty == (channels <= 2))
        }
    }

    @Test(arguments: [0.99995, 1.00005]) func hourOfDeviceDriftDoesNotChangeSamples(scalar: Double) throws {
        let writer = SinkWriter(); writer.retainPCM = false
        let failures = Failures()
        let sink = RecordingSink(session: writer, originHostTime: 1) { failures.add($0) }
        let input = try buffer(channels: 1, frames: 64000)
        // Drain each block deterministically by waiting for a fresh per-source budget.
        for index in 0..<450 {
            sink.receive(input, hostTime: 1 + AVAudioTime.hostTime(forSeconds: Double(index) * 8 * scalar),
                         id: "x", label: "Input", kind: "microphone")
            sink.flush()
        }
        try sink.finish(problem: nil)
        #expect(failures.count == 0)
        #expect(writer.bytes == 3600 * 8000 * 2)
        #expect(writer.chunks.count == 450)
        for (index, chunk) in writer.chunks.enumerated() { #expect(abs(chunk.2 - Double(index) * 8000) < 0.0001) }
        #expect(sink.status().droppedMs == 0)
    }

    @Test func diskStallIsBoundedPerSourceAndTailIsCountedSilence() throws {
        let writer = SinkWriter(); writer.stall = true
        let failures = Failures()
        let sink = RecordingSink(session: writer, capacitySeconds: 0.01, originHostTime: 1) { failures.add($0) }
        let input = try buffer(channels: 1, frames: 80)
        sink.receive(input, hostTime: 1, id: "a", label: "A", kind: "system")
        #expect(writer.entered.wait(timeout: .now() + 2) == .success)
        sink.receive(input, hostTime: 1, id: "a", label: "A", kind: "system") // counted drop
        sink.receive(input, hostTime: 1, id: "b", label: "B", kind: "microphone") // independent budget
        #expect(sink.status().droppedMs == 10)
        writer.release.signal()
        #expect(throws: (any Error).self) { try sink.finish(problem: nil) }
        #expect(failures.count == 0)
        #expect(writer.finishes == 1)
        #expect(writer.chunks.map { $0.0 } == ["a", "b", "a"])
        #expect(writer.chunks.last?.2 == 10)
        #expect(writer.chunks.last?.1.allSatisfy { $0 == 0 } == true)
        #expect(writer.recordingProblem?.contains("10 ms") == true)
    }

    @Test func pausePadsDroppedTailOnceAndResumeKeepsTheSameWriter() throws {
        let writer = SinkWriter(); writer.stall = true
        let failures = Failures()
        let sink = RecordingSink(session:writer,capacitySeconds:0.01,originHostTime:1) { failures.add($0) }
        let input = try buffer(channels:1,frames:80)
        sink.receive(input,hostTime:1,id:"a",label:"A",kind:"microphone")
        #expect(writer.entered.wait(timeout:.now()+2) == .success)
        sink.receive(input,hostTime:1+AVAudioTime.hostTime(forSeconds:0.01),id:"a",label:"A",kind:"microphone")
        writer.release.signal()
        try sink.pause()
        #expect(writer.finishes == 0)
        #expect(writer.chunks.count == 2)
        #expect(writer.chunks.last?.1.allSatisfy { $0 == 0 } == true)
        sink.receive(input,hostTime:1+AVAudioTime.hostTime(forSeconds:0.02),id:"a",label:"A",kind:"microphone")
        try sink.resume()
        sink.receive(input,hostTime:1+AVAudioTime.hostTime(forSeconds:0.02),id:"a",label:"A",kind:"microphone")
        #expect(throws:(any Error).self) { try sink.finish(problem:nil) }
        #expect(writer.bytes == 3*80*2)
        #expect(writer.chunks.map { $0.2 } == [0,10,20])
        #expect(writer.formats.count == 1); #expect(writer.finishes == 1)
        #expect(failures.count == 0)
    }

    @Test func failureOnceAndLateCallbacksAreHarmless() throws {
        let writer = SinkWriter(); writer.reject = true
        let failures = Failures()
        let sink = RecordingSink(session: writer, originHostTime: 1) { failures.add($0) }
        let input = try buffer(channels: 1)
        for _ in 0..<10 { sink.receive(input, hostTime: 1, id: "x", label: "X", kind: "microphone") }
        try sink.finish(problem: "Injected failure")
        #expect(failures.count == 1)
        #expect(writer.finishes == 1)
        sink.receive(input, hostTime: 1, id: "x", label: "X", kind: "microphone")
        try sink.finish(problem: nil)
        #expect(failures.count == 1)
        #expect(writer.finishes == 1)
    }

    @Test func changedFormatFailsOnce() throws {
        let writer = SinkWriter(), failures = Failures()
        let sink = RecordingSink(session: writer, originHostTime: 1) { failures.add($0) }
        sink.receive(try buffer(channels: 1), hostTime: 1, id: "x", label: "X", kind: "microphone")
        sink.receive(try buffer(channels: 2), hostTime: 1, id: "x", label: "X", kind: "microphone")
        sink.receive(try buffer(channels: 2), hostTime: 1, id: "x", label: "X", kind: "microphone")
        try sink.finish(problem: "Format changed")
        #expect(failures.count == 1)
    }
}
