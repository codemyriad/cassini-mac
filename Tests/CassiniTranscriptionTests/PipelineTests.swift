// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
import Foundation
import CryptoKit
import CassiniWhistle
@testable import CassiniTranscription

final class PipelineTests: XCTestCase {
    private var root: URL { Bundle.module.url(forResource: "Goldens", withExtension: nil)! }
    func testSharedGoldenChecksums() throws {
        let manifest = try String(contentsOf: root.appendingPathComponent("SHA256SUMS"), encoding: .utf8)
        for line in manifest.split(separator: "\n") {
            let fields = line.split(whereSeparator: \.isWhitespace)
            XCTAssertEqual(fields.count,2)
            let bytes = try Data(contentsOf: root.appendingPathComponent(String(fields[1])))
            let actual = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            XCTAssertEqual(actual,String(fields[0]),String(fields[1]))
        }
    }
    func testStreamingFIRMatchesGoldenAndBatchBoundaries() throws {
        var input: [Float] = []
        try MeetingAudioDecoder.decode(root.appendingPathComponent("pipeline-input-48k.wav")) { pcm, rate in XCTAssertEqual(rate, 48000); input += pcm }
        let data = try Data(contentsOf: root.appendingPathComponent("pipeline-resampled-16k.f32"))
        let golden: [Float] = data.withUnsafeBytes { b in (0..<b.count / 4).map { b.loadUnaligned(fromByteOffset: $0 * 4, as: Float.self) } }
        var filter = try MeetingResampler(rate: 48000), output: [Float] = []
        for at in stride(from: 0, to: input.count, by: 997) { output += filter.feed(Array(input[at..<min(input.count, at + 997)])) }
        output += filter.feed([], final: true)
        XCTAssertEqual(output.count, golden.count)
        XCTAssertLessThanOrEqual(zip(output, golden).map { abs($0 - $1) }.max()!, 1e-6)
        var single = try MeetingResampler(rate: 48000)
        XCTAssertEqual(output, single.feed(input, final: true))
    }
    func testGateVotesPreRollDurationAndFlush() throws {
        var gate = SpeechGate()
        let silent = [Float](repeating: 0, count: 512), voice = [Float](repeating: 1, count: 512)
        XCTAssertTrue(gate.feed(silent) { $0[0] }.isEmpty)
        XCTAssertTrue(gate.feed(voice) { $0[0] }.isEmpty)
        XCTAssertTrue(gate.feed(voice) { $0[0] }.isEmpty)
        var ends: [SpeechSegment] = []
        for _ in 0..<19 { ends += gate.feed(silent) { $0[0] } }
        XCTAssertEqual(ends, [.init(startSample: 0, endSample: 11264, reason: "silence")])
        XCTAssertTrue(gate.flush().isEmpty)
        gate = SpeechGate()
        ends = gate.feed([Float](repeating: 1, count: 16000 * 16)) { $0[0] }
        XCTAssertEqual(ends.first?.endSample, 240128)
        XCTAssertEqual(ends.first?.reason, "durationLimit")
        XCTAssertEqual(gate.flush().last?.reason, "flush")
    }
    func testTextExceptionRejectsOtherWordsInputsAndGoldens() throws {
        let policy = try MacTextExceptions.load(root), rule = try XCTUnwrap(policy.exceptions.first)
        let segment = SpeechSegment(startSample: 318976, endSample: 458240, reason: "silence")
        XCTAssertNotNil(policy.entry(golden: rule.golden, goldenHash: rule.goldenSha256, segmentIndex: 5, segment: segment, actualHash: rule.segmentInputSha256, referenceHash: rule.segmentInputSha256))
        XCTAssertNil(policy.entry(golden: rule.golden, goldenHash: rule.goldenSha256, segmentIndex: 5, segment: segment, actualHash: "wrong", referenceHash: rule.segmentInputSha256))
        XCTAssertNil(policy.entry(golden: "pipeline-golden.json", goldenHash: rule.goldenSha256, segmentIndex: 5, segment: segment, actualHash: rule.segmentInputSha256, referenceHash: rule.segmentInputSha256))
        XCTAssertNil(policy.entry(golden: rule.golden, goldenHash: "wrong", segmentIndex: 5, segment: segment, actualHash: rule.segmentInputSha256, referenceHash: rule.segmentInputSha256))
        var segments = Array(repeating: segment, count: 8), hashes = Array(repeating: ["actual":rule.segmentInputSha256,"expected":rule.segmentInputSha256], count: 8)
        func permits(_ index: Int, _ text: String = "ask") -> Bool {
            policy.permitsWord(golden: rule.golden, goldenHash: rule.goldenSha256, index: index, actual: text, expected: "as", segments: segments, hashes: hashes)
        }
        XCTAssertTrue(permits(37)); XCTAssertFalse(permits(36)); XCTAssertFalse(permits(38)); XCTAssertFalse(permits(37,"another"))
        hashes[5] = [:]; XCTAssertFalse(permits(37))
        hashes[5] = ["actual":rule.segmentInputSha256,"expected":rule.segmentInputSha256]
        segments[5] = .init(startSample: 318975,endSample: 458240,reason:"silence"); XCTAssertFalse(permits(37))
    }
    func testBothPinnedModelGoldens() throws {
        guard let directory = ProcessInfo.processInfo.environment["CASSINI_PIPELINE_ASSETS"] else { throw XCTSkip("Pinned offline assets supplied by pipeline CI") }
        let policy = try MacTextExceptions.load(root)
        let arguments = ["--assets", directory]
        let assets = try VADAssets.forWorker(arguments: arguments)
        let detector = try SpeechDetector(assets: assets)
        let engine = try WhistleEngine(assets: WhistleAssets.forWorker(arguments: arguments))
        struct Golden: Decodable {
            struct Segment: Decodable { let startSample: Int; let endSample: Int; let reason: String; let text: String }
            struct Word: Codable, Equatable { let startMs: Int64; let endMs: Int64; let text: String }
            let input: String; let segments: [Segment]; let words: [Word]
        }
        for name in ["whistle-golden", "pipeline-golden"] {
            let goldenBytes = try Data(contentsOf: root.appendingPathComponent(name + ".json"))
            let golden = try JSONDecoder().decode(Golden.self, from: goldenBytes)
            let goldenHash = SHA256.hash(data: goldenBytes).map { String(format: "%02x", $0) }.joined()
            let audio = try SegmentedAudio(url: root.appendingPathComponent(golden.input), detector: detector)
            XCTAssertEqual(audio.segments, golden.segments.map { .init(startSample: $0.startSample, endSample: $0.endSample, reason: $0.reason) }, name)
            var reference: [Float] = []
            if name == "pipeline-golden" {
                let bytes = try Data(contentsOf: root.appendingPathComponent("pipeline-resampled-16k.f32"))
                reference = bytes.withUnsafeBytes { b in (0..<b.count / 4).map { b.loadUnaligned(fromByteOffset: $0 * 4, as: Float.self) } }
            } else { try MeetingAudioDecoder.decode(root.appendingPathComponent(golden.input)) { pcm, _ in reference += pcm } }
            var hashes: [[String:String]] = []
            var words: [Golden.Word] = []
            for (index, segment) in audio.segments.enumerated() {
                let samples = try audio.samples(segment)
                func sha(_ values: [Float]) -> String { values.withUnsafeBytes { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() } }
                let actualHash = sha(samples), expectedHash = sha(Array(reference[segment.startSample..<segment.endSample]))
                XCTAssertEqual(actualHash, expectedHash, name + " segment input \(index), required by D11.3")
                hashes.append(["actual":actualHash,"expected":expectedHash])
                let transcript = try engine.transcribe(samples: samples)
                let scoped = policy.entry(golden: name + ".json", goldenHash: goldenHash, segmentIndex: index, segment: segment, actualHash: actualHash, referenceHash: expectedHash)
                let allowed = scoped.map { $0.expectedSegmentText == golden.segments[index].text && $0.actualSegmentText == transcript.text } ?? false
                if !allowed { XCTAssertEqual(transcript.text, golden.segments[index].text, name + " segment \(index)") }
                let start = Int64(segment.startSample * 1000 / 16000)
                for word in transcript.words ?? [] {
                    let beginMs = Int64((word.start * 1000).rounded(.toNearestOrEven))
                    let endMs = Int64((word.end * 1000).rounded(.toNearestOrEven))
                    words.append(Golden.Word(startMs: start + beginMs, endMs: start + endMs, text: word.word))
                }
            }
            if let path = ProcessInfo.processInfo.environment["CASSINI_PIPELINE_REPORT_DIR"] {
                let folder = URL(fileURLWithPath: path)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try JSONEncoder().encode(hashes).write(to: folder.appendingPathComponent(name + "-segment-hashes.json"))
                try JSONEncoder().encode(words).write(to: folder.appendingPathComponent(name + "-actual-words.json"))
                try JSONEncoder().encode(audio.segments).write(to: folder.appendingPathComponent(name + "-actual-segments.json"))
            }
            XCTAssertEqual(words.count, golden.words.count, name)
            for (index, pair) in zip(words, golden.words).enumerated() {
                let allowed = policy.permitsWord(golden: name + ".json", goldenHash: goldenHash, index: index, actual: pair.0.text, expected: pair.1.text, segments: audio.segments, hashes: hashes)
                if !allowed { XCTAssertEqual(pair.0.text, pair.1.text, name + " word \(index)") }
                XCTAssertLessThanOrEqual(abs(pair.0.startMs - pair.1.startMs), 80, name + " word \(index) start")
                XCTAssertLessThanOrEqual(abs(pair.0.endMs - pair.1.endMs), 80, name + " word \(index) end")
            }
        }
    }
}
