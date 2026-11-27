// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import Foundation
import XCTest
import CassiniParakeet
import CassiniWhistle
@testable import CassiniTranscription

final class ParakeetSampleRateAcceptanceTests: XCTestCase {
    private static let requestedRates = [44_100, 32_000, 24_000, 96_000]

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

    func testParakeetTranscriberAcceptsAnyRate() throws {
        let env = ProcessInfo.processInfo.environment
        guard let runtime = env["CASSINI_PARAKEET_RUNTIME"],
              let model = env["CASSINI_PARAKEET_MODEL"],
              let pipeline = env["CASSINI_PIPELINE_ASSETS"] else {
            throw XCTSkip("Pinned Parakeet runtime/model and VAD assets supplied by Parakeet CI")
        }

        let jfkURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("CassiniTranscriptionTests/Goldens/jfk.wav")
        XCTAssertTrue(FileManager.default.fileExists(atPath: jfkURL.path), "Expected jfk.wav golden at \(jfkURL.path)")

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("ParakeetSampleRateAcceptance-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let assets = try ParakeetAssets.pinned(runtime: URL(fileURLWithPath: runtime), model: URL(fileURLWithPath: model))
        let engine = try ParakeetEngine(assets: assets)
        let detector = try SpeechDetector(assets: VADAssets.forWorker(arguments: ["--assets", pipeline]))

        let source16k = try decodeSource16kSamples(jfkURL)
        let baseline16kURL = tempDir.appendingPathComponent("jfk-16000.wav")
        try writeResampledWAV(from16k: source16k, toRate: 16_000, outputURL: baseline16kURL)

        // Prerequisite: 16 kHz baseline Parakeet transcription must succeed outside expected-failure scope.
        let baselineSeg = try SegmentedAudio(url: baseline16kURL, detector: detector)
        let baselineWords = try baselineSeg.segments.flatMap { segment in
            let transcript = try engine.transcribe(samples: try baselineSeg.samples(segment))
            return normalizeWords(transcript.words ?? [])
        }
        XCTAssertFalse(baselineWords.isEmpty, "Baseline 16 kHz Parakeet transcription must produce words")

        enum ParakeetRateOutcome {
            case audioFormatRejected
            case transcribed([String])
        }

        var outcomes: [(rate: Int, outcome: ParakeetRateOutcome)] = []
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

        expectStrictFailure("D-1196 item 4 (Parakeet)", matching: "[D-1196-item4-parakeet]") {
            for (rate, outcome) in outcomes {
                switch outcome {
                case .audioFormatRejected:
                    XCTFail("[D-1196-item4-parakeet] Parakeet rejected \(rate) Hz with TranscriptionFailure.audioFormat")
                case let .transcribed(words):
                    XCTAssertEqual(words, baselineWords, "[D-1196-item4-parakeet] Parakeet words at \(rate) Hz must match 16 kHz baseline")
                }
            }
        }
    }
}
