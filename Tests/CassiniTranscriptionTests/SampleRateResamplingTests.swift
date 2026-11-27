// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
import CassiniRecording
import CassiniWhistle
@testable import CassiniTranscription

private final class AlwaysVoicedDetector: SpeechProbabilityProvider {
    private var frames = 0
    func reset() { frames = 0 }
    func probability(_ frame: [Float]) throws -> Float {
        frames += 1
        // Voice for first ~1.5 s (48 frames = 1.536 s), then silence so SpeechGate closes a segment.
        return frames <= 48 ? 0.9 : 0.05
    }
}

private func writeMonoWAV(url: URL, sampleRate: Int, seconds: Double, frequency: Double = 440) throws {
    let frameCount = Int((Double(sampleRate) * seconds).rounded())
    var pcm = Data(capacity: frameCount * 2)
    for i in 0..<frameCount {
        let sample = Int16((0.35 * sin(2 * Double.pi * frequency * Double(i) / Double(sampleRate)) * 32767).rounded()).littleEndian
        withUnsafeBytes(of: sample) { pcm.append(contentsOf: $0) }
    }
    var header = Data()
    func appendString(_ s: String) { header.append(contentsOf: s.utf8) }
    func appendInt<T: FixedWidthInteger>(_ n: T) {
        var le = n.littleEndian
        withUnsafeBytes(of: &le) { header.append(contentsOf: $0) }
    }
    let dataBytes = UInt32(pcm.count)
    appendString("RIFF"); appendInt(dataBytes + 36); appendString("WAVEfmt "); appendInt(UInt32(16))
    appendInt(UInt16(1)); appendInt(UInt16(1)); appendInt(UInt32(sampleRate))
    appendInt(UInt32(sampleRate * 2)); appendInt(UInt16(2)); appendInt(UInt16(16))
    appendString("data"); appendInt(dataBytes)
    try (header + pcm).write(to: url)
}

@Suite struct SampleRateResamplingTests {
    @Test(arguments: [44_100, 32_000, 24_000, 96_000, 22_050, 8_000])
    func meetingResamplerAcceptsAnyValidRate(rate: Int) throws {
        var resampler = try MeetingResampler(rate: rate)
        let totalIn = rate // 1.0 second
        let signal: [Float] = (0..<totalIn).map { i in
            0.4 * Float(sin(2 * Double.pi * 440 * Double(i) / Double(rate)))
        }
        var output: [Float] = []
        for start in stride(from: 0, to: signal.count, by: 997) {
            let end = min(signal.count, start + 997)
            output += resampler.feed(Array(signal[start..<end]), final: false)
        }
        output += resampler.feed([], final: true)

        #expect(output.allSatisfy { $0.isFinite })
        // 1 second at 16 kHz = 16000 samples (allow ±160 samples = ±10 ms for converter filter latency).
        #expect(abs(output.count - 16_000) <= 160)
        // Energy of the 440 Hz tone must be preserved (RMS of 0.4 sine is ~0.283).
        let rms = sqrt(output.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(output.count))
        #expect(rms > 0.20 && rms < 0.35)
    }

    @Test func meetingResamplerRejectsOutOfRangeRates() {
        #expect(throws: (any Error).self) { _ = try MeetingResampler(rate: 0) }
        #expect(throws: (any Error).self) { _ = try MeetingResampler(rate: 7_999) }
        #expect(throws: (any Error).self) { _ = try MeetingResampler(rate: 192_001) }
    }

    @Test(arguments: [44_100, 32_000, 24_000, 96_000])
    func decoderAndSegmentedAudioAcceptAnyRate(rate: Int) throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("CassiniDecode-\(rate)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let wav = dir.appendingPathComponent("track.wav")
        try writeMonoWAV(url: wav, sampleRate: rate, seconds: 2.5)

        let audio = try SegmentedAudio(url: wav, detector: AlwaysVoicedDetector())
        // 2.5 s at 16 kHz = 40000 samples (±10 ms = ±160 samples).
        #expect(abs(audio.sampleCount - 40_000) <= 160)
        #expect(!audio.segments.isEmpty)
        let segmentSamples = try audio.samples(audio.segments[0])
        #expect(!segmentSamples.isEmpty)
        #expect(segmentSamples.allSatisfy { $0.isFinite })
    }

    @Test func sessionFollowerFollows44100HzTrackAndHandsOffCleanly() throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("CassiniFollower44k-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: parent) }

        let session = try RecordingSession(parent: parent, title: "Bluetooth 44.1k", source: "macos")
        try session.addTrack(id: "microphone", label: "Mic", kind: "microphone", sampleRate: 44_100, channels: 1)

        // Append 2.5 seconds of 44.1 kHz mono PCM in 0.5 s chunks so SpeechGate closes a segment.
        let chunkFrames = 22_050
        for chunkIndex in 0..<5 {
            var pcm = Data(capacity: chunkFrames * 2)
            for i in 0..<chunkFrames {
                let sampleIndex = chunkIndex * chunkFrames + i
                let sample = Int16((0.3 * sin(2 * Double.pi * 440 * Double(sampleIndex) / 44_100) * 32767).rounded()).littleEndian
                withUnsafeBytes(of: sample) { pcm.append(contentsOf: $0) }
            }
            try session.appendNative(id: "microphone", pcm: pcm, offsetMs: Double(chunkIndex) * 500)
        }
        try session.finish(problem: nil)

        var recognizedCount = 0
        let follower = try SessionFollower(
            directory: session.directory,
            modelIdentity: "test-model",
            makeDetector: { AlwaysVoicedDetector() },
            recognize: { _ in
                recognizedCount += 1
                return WhistleTranscript(
                    text: "hello",
                    language: "en",
                    words: [.init(word: "hello", start: 0.0, end: 0.5, probability: 1.0)]
                )
            }
        )

        var steps = 0
        while try follower.step() {
            steps += 1
            if steps > 100 { break }
        }

        #expect(follower.stats.tracksFollowed == 1)
        #expect(follower.stats.blocksDecoded > 0)
        #expect(follower.stats.segmentsClosed >= 1)
        #expect(recognizedCount >= 1)

        let prefixes = follower.takeVerifiedPrefixes()
        let prefix = try #require(prefixes.values.first)
        let audio = try SegmentedAudio(url: prefix.url, detector: AlwaysVoicedDetector(), precomputedPrefix: prefix)
        #expect(audio.reusedVerifiedPrefix)
        #expect(abs(audio.sampleCount - 40_000) <= 160)
    }
}
