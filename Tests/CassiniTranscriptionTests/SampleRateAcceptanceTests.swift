// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import Foundation
import XCTest
import CassiniRecording
import CassiniWhistle
@testable import CassiniTranscription

final class SampleRateAcceptanceTests: XCTestCase {
    private final class DeterministicSpeechDetector: SpeechProbabilityProvider {
        private var hpf = SileroInputHighPass()
        func reset() { hpf = SileroInputHighPass() }
        func probability(_ frame: [Float]) throws -> Float {
            guard frame.count == 512 else { throw TranscriptionFailure.audioFormat }
            let filtered = hpf.process(frame)
            var sumSq: Float = 0
            for s in filtered { sumSq += s * s }
            let rms = (sumSq / Float(filtered.count)).squareRoot()
            return rms >= 0.02 ? 0.92 : 0.02
        }
    }

    private func writeCanonicalWAV(samples: [Int16], sampleRate: Int, channels: Int = 1, to url: URL) throws {
        var header = Data()
        let dataSize = UInt32(samples.count * 2)
        let riffSize = 36 + dataSize
        let byteRate = UInt32(sampleRate * channels * 2)
        let blockAlign = UInt16(channels * 2)
        func appendLE<T: FixedWidthInteger>(_ v: T) {
            var le = v.littleEndian
            withUnsafeBytes(of: &le) { header.append(contentsOf: $0) }
        }
        header.append(contentsOf: "RIFF".utf8)
        appendLE(riffSize)
        header.append(contentsOf: "WAVEfmt ".utf8)
        appendLE(UInt32(16))
        appendLE(UInt16(1))
        appendLE(UInt16(channels))
        appendLE(UInt32(sampleRate))
        appendLE(byteRate)
        appendLE(blockAlign)
        appendLE(UInt16(16))
        header.append(contentsOf: "data".utf8)
        appendLE(dataSize)
        var body = Data(capacity: samples.count * 2)
        for sample in samples {
            var le = sample.littleEndian
            withUnsafeBytes(of: &le) { body.append(contentsOf: $0) }
        }
        try (header + body).write(to: url, options: .atomic)
    }

    private func resample16kWAV(_ inputURL: URL, toRate targetRate: Int, outputURL: URL) throws {
        var sourceSamples: [Float] = []
        try MeetingAudioDecoder.decode(inputURL) { pcm, rate in
            XCTAssertEqual(rate, 16_000)
            sourceSamples.append(contentsOf: pcm)
        }
        let inFormat = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let outFormat = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: Double(targetRate), channels: 1))
        let converter = try XCTUnwrap(AVAudioConverter(from: inFormat, to: outFormat))
        let inBuffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: AVAudioFrameCount(sourceSamples.count)))
        inBuffer.frameLength = AVAudioFrameCount(sourceSamples.count)
        for i in 0..<sourceSamples.count {
            inBuffer.floatChannelData![0][i] = sourceSamples[i]
        }
        let expectedOutFrames = AVAudioFrameCount(ceil(Double(sourceSamples.count) * Double(targetRate) / 16_000.0)) + 256
        let outBuffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: expectedOutFrames))
        var consumed = false
        var convError: NSError?
        converter.convert(to: outBuffer, error: &convError) { _, outStatus in
            if consumed {
                outStatus.pointee = .endOfStream
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return inBuffer
        }
        if let convError { throw convError }
        let count = Int(outBuffer.frameLength)
        var int16Samples = [Int16]()
        int16Samples.reserveCapacity(count)
        for i in 0..<count {
            let v = max(-1.0, min(1.0, outBuffer.floatChannelData![0][i]))
            int16Samples.append(Int16((v * 32767.0).rounded()))
        }
        try writeCanonicalWAV(samples: int16Samples, sampleRate: targetRate, to: outputURL)
    }

    func testTranscriberAcceptsAnyRate() throws {
        let options = XCTExpectedFailure.Options()
        options.isStrict = true
        XCTExpectFailure("D-1196 item 4", options: options) {
            do {
                try runTranscriberAcceptsAnyRate()
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
        }
    }

    private func runTranscriberAcceptsAnyRate() throws {
        let jfkURL = try XCTUnwrap(Bundle.module.url(forResource: "jfk", withExtension: "wav", subdirectory: "Goldens"))
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("SampleRateAcceptance-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Baseline 16 kHz segmentation.
        let baselineAudio = try SegmentedAudio(url: jfkURL, detector: DeterministicSpeechDetector())
        XCTAssertFalse(baselineAudio.segments.isEmpty, "Baseline 16 kHz jfk.wav must produce speech segments")

        // Optional real Whistle engine when offline assets are supplied in CI.
        let whistleEngine: WhistleEngine?
        let realDetector: SpeechDetector?
        if let assetsDir = ProcessInfo.processInfo.environment["CASSINI_PIPELINE_ASSETS"] {
            let args = ["--assets", assetsDir]
            realDetector = try SpeechDetector(assets: VADAssets.forWorker(arguments: args))
            whistleEngine = try WhistleEngine(assets: WhistleAssets.forWorker(arguments: args))
        } else {
            realDetector = nil
            whistleEngine = nil
        }

        let baselineWords: [String]? = try {
            guard let engine = whistleEngine, let detector = realDetector else { return nil }
            let seg = try SegmentedAudio(url: jfkURL, detector: detector)
            return try seg.segments.flatMap { segment in
                let transcript = try engine.transcribe(samples: try seg.samples(segment))
                return (transcript.words ?? []).map { $0.word.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }.filter { !$0.isEmpty }
            }
        }()

        // Resample jfk.wav to 44.1, 32, 24 and 96 kHz and run each through the transcription pipeline.
        for rate in [44_100, 32_000, 24_000, 96_000] {
            let resampledURL = tempDir.appendingPathComponent("jfk-\(rate).wav")
            try resample16kWAV(jfkURL, toRate: rate, outputURL: resampledURL)

            let segmented = try SegmentedAudio(url: resampledURL, detector: DeterministicSpeechDetector())
            XCTAssertFalse(segmented.segments.isEmpty, "Rate \(rate) Hz must decode and segment speech")
            XCTAssertEqual(Double(segmented.sampleCount), Double(baselineAudio.sampleCount), accuracy: 800, "Rate \(rate) Hz resampled length must match 16 kHz baseline")

            if let engine = whistleEngine, let detector = realDetector, let expectedWords = baselineWords {
                detector.reset()
                let realSeg = try SegmentedAudio(url: resampledURL, detector: detector)
                let words = try realSeg.segments.flatMap { segment in
                    let transcript = try engine.transcribe(samples: try realSeg.samples(segment))
                    return (transcript.words ?? []).map { $0.word.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }.filter { !$0.isEmpty }
                }
                XCTAssertEqual(words, expectedWords, "Whistle words at \(rate) Hz must match 16 kHz baseline")
            }
        }

        // SessionFollower must follow a 44.1 kHz track instead of skipping it.
        let sessionDir = tempDir.appendingPathComponent("session-44k")
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        let trackURL = sessionDir.appendingPathComponent("track-1.wav")
        try FileManager.default.copyItem(at: tempDir.appendingPathComponent("jfk-44100.wav"), to: trackURL)
        let sessionJSON: [String: Any] = [
            "version": 1,
            "id": UUID().uuidString,
            "title": "44.1 kHz follower test",
            "createdAt": "2026-11-27T10:00:00Z",
            "source": "macos",
            "tracks": [
                [
                    "id": "microphone",
                    "label": "Microphone",
                    "kind": "microphone",
                    "file": "track-1.wav",
                    "sampleRate": 44_100,
                    "channels": 1,
                    "startOffsetMs": 0
                ]
            ]
        ]
        let sessionData = try JSONSerialization.data(withJSONObject: sessionJSON, options: [.sortedKeys])
        try sessionData.write(to: sessionDir.appendingPathComponent("session.json"), options: .atomic)

        let follower = try SessionFollower(
            directory: sessionDir,
            modelIdentity: WhistleAssets.modelIdentity,
            makeDetector: { DeterministicSpeechDetector() },
            recognize: { _ in WhistleTranscript(text: "ok", language: "en", words: []) }
        )
        let didWork = try follower.step()
        XCTAssertTrue(didWork, "SessionFollower must process a 44.1 kHz track instead of skipping it")
        XCTAssertEqual(follower.stats.tracksFollowed, 1, "SessionFollower must follow the 44.1 kHz track")
        XCTAssertGreaterThan(follower.stats.blocksDecoded, 0)
    }
}
