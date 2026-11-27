// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import Foundation
import XCTest
import CassiniRecording
import CassiniWhistle
@testable import CassiniTranscription

final class SampleRateAcceptanceTests: XCTestCase {
    private static let requestedRates = [44_100, 32_000, 24_000, 96_000]

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

    private func decodeSource16kSamples(_ inputURL: URL) throws -> [Float] {
        let audio = try AVAudioFile(forReading: inputURL, commonFormat: .pcmFormatFloat32, interleaved: false)
        let format = audio.processingFormat
        XCTAssertEqual(Int(format.sampleRate), 16_000, "Source fixture must be 16 kHz")
        let frameCount = AVAudioFrameCount(audio.length)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount))
        try audio.read(into: buffer)
        let data = try XCTUnwrap(buffer.floatChannelData)
        return Array(UnsafeBufferPointer(start: data[0], count: Int(buffer.frameLength)))
    }

    private func writeResampledWAV(from16k sourceSamples: [Float], toRate targetRate: Int, outputURL: URL) throws {
        if targetRate == 16_000 {
            let int16Samples = sourceSamples.map { Int16((max(-1.0, min(1.0, $0)) * 32767.0).rounded()) }
            try writeCanonicalWAV(samples: int16Samples, sampleRate: 16_000, to: outputURL)
            return
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

    private func normalizeWords(_ words: [WhistleTranscript.Word]) -> [String] {
        words.map { $0.word.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
    }

    func testTranscriberAcceptsAnyRate() throws {
        let jfkURL = try XCTUnwrap(Bundle.module.url(forResource: "jfk", withExtension: "wav", subdirectory: "Goldens"))
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("SampleRateAcceptance-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Prerequisite: write canonical 16 kHz baseline WAV and verify segmentation succeeds outside expected-failure scope.
        let source16k = try decodeSource16kSamples(jfkURL)
        let baseline16kURL = tempDir.appendingPathComponent("jfk-16000.wav")
        try writeResampledWAV(from16k: source16k, toRate: 16_000, outputURL: baseline16kURL)

        let baselineAudio = try SegmentedAudio(url: baseline16kURL, detector: DeterministicSpeechDetector())
        XCTAssertFalse(baselineAudio.segments.isEmpty, "Baseline 16 kHz jfk.wav must produce speech segments")

        enum SegmentationOutcome {
            case audioFormatRejected
            case segmented(segmentCount: Int, sampleCount: Int)
        }

        var outcomes: [(rate: Int, outcome: SegmentationOutcome)] = []
        for rate in Self.requestedRates {
            let resampledURL = tempDir.appendingPathComponent("jfk-\(rate).wav")
            try writeResampledWAV(from16k: source16k, toRate: rate, outputURL: resampledURL)
            do {
                let segmented = try SegmentedAudio(url: resampledURL, detector: DeterministicSpeechDetector())
                outcomes.append((rate, .segmented(segmentCount: segmented.segments.count, sampleCount: segmented.sampleCount)))
            } catch TranscriptionFailure.audioFormat {
                outcomes.append((rate, .audioFormatRejected))
            }
        }

        // Prerequisite: prepare 44.1 kHz session for SessionFollower outside expected-failure scope.
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
        enum FollowerOutcome {
            case audioFormatRejected
            case stepped(didWork: Bool, tracksFollowed: Int, blocksDecoded: Int)
        }

        let followerOutcome: FollowerOutcome
        do {
            let didWork = try follower.step()
            followerOutcome = .stepped(
                didWork: didWork,
                tracksFollowed: follower.stats.tracksFollowed,
                blocksDecoded: follower.stats.blocksDecoded
            )
        } catch TranscriptionFailure.audioFormat {
            followerOutcome = .audioFormatRejected
        }

        expectStrictFailure("D-1196 item 4", matching: "[D-1196-item4]") {
            for (rate, outcome) in outcomes {
                switch outcome {
                case .audioFormatRejected:
                    XCTFail("[D-1196-item4] Rate \(rate) Hz rejected with TranscriptionFailure.audioFormat")
                case let .segmented(segmentCount, sampleCount):
                    XCTAssertGreaterThan(segmentCount, 0, "[D-1196-item4] Rate \(rate) Hz must decode and segment speech")
                    XCTAssertEqual(Double(sampleCount), Double(baselineAudio.sampleCount), accuracy: 800, "[D-1196-item4] Rate \(rate) Hz resampled length must match 16 kHz baseline")
                }
            }
            switch followerOutcome {
            case .audioFormatRejected:
                XCTFail("[D-1196-item4] SessionFollower rejected 44.1 kHz track with TranscriptionFailure.audioFormat")
            case let .stepped(didWork, tracksFollowed, blocksDecoded):
                XCTAssertTrue(didWork, "[D-1196-item4] SessionFollower must process a 44.1 kHz track instead of skipping it")
                XCTAssertEqual(tracksFollowed, 1, "[D-1196-item4] SessionFollower must follow the 44.1 kHz track")
                XCTAssertGreaterThan(blocksDecoded, 0, "[D-1196-item4] SessionFollower must decode blocks from 44.1 kHz track")
            }
        }
    }

    func testWhistleTranscriberAcceptsAnyRate() throws {
        guard let assetsDir = ProcessInfo.processInfo.environment["CASSINI_PIPELINE_ASSETS"] else {
            throw XCTSkip("Pinned Whistle and VAD assets supplied by Whistle CI")
        }
        let jfkURL = try XCTUnwrap(Bundle.module.url(forResource: "jfk", withExtension: "wav", subdirectory: "Goldens"))
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("WhistleSampleRateAcceptance-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let args = ["--assets", assetsDir]
        let detector = try SpeechDetector(assets: VADAssets.forWorker(arguments: args))
        let engine = try WhistleEngine(assets: WhistleAssets.forWorker(arguments: args))

        let source16k = try decodeSource16kSamples(jfkURL)
        let baseline16kURL = tempDir.appendingPathComponent("jfk-16000.wav")
        try writeResampledWAV(from16k: source16k, toRate: 16_000, outputURL: baseline16kURL)

        // Prerequisite: 16 kHz baseline Whistle transcription must succeed outside expected-failure scope.
        let baselineSeg = try SegmentedAudio(url: baseline16kURL, detector: detector)
        let baselineWords = try baselineSeg.segments.flatMap { segment in
            let transcript = try engine.transcribe(samples: try baselineSeg.samples(segment))
            return normalizeWords(transcript.words ?? [])
        }
        XCTAssertFalse(baselineWords.isEmpty, "Baseline 16 kHz Whistle transcription must produce words")

        enum WhistleRateOutcome {
            case audioFormatRejected
            case transcribed([String])
        }

        var outcomes: [(rate: Int, outcome: WhistleRateOutcome)] = []
        for rate in Self.requestedRates {
            let resampledURL = tempDir.appendingPathComponent("jfk-\(rate).wav")
            try writeResampledWAV(from16k: source16k, toRate: rate, outputURL: resampledURL)
            detector.reset()
            do {
                let seg = try SegmentedAudio(url: resampledURL, detector: detector)
                let words = try seg.segments.flatMap { segment in
                    let transcript = try engine.transcribe(samples: try seg.samples(segment))
                    return normalizeWords(transcript.words ?? [])
                }
                outcomes.append((rate, .transcribed(words)))
            } catch TranscriptionFailure.audioFormat {
                outcomes.append((rate, .audioFormatRejected))
            }
        }

        expectStrictFailure("D-1196 item 4 (Whistle)", matching: "[D-1196-item4-whistle]") {
            for (rate, outcome) in outcomes {
                switch outcome {
                case .audioFormatRejected:
                    XCTFail("[D-1196-item4-whistle] Whistle rejected \(rate) Hz with TranscriptionFailure.audioFormat")
                case let .transcribed(words):
                    XCTAssertEqual(words, baselineWords, "[D-1196-item4-whistle] Whistle words at \(rate) Hz must match 16 kHz baseline")
                }
            }
        }
    }
}
