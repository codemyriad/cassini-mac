// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
import Foundation
import CryptoKit
import CassiniWhistle
import CassiniParakeet
@testable import CassiniTranscription

final class ParakeetGoldenTests: XCTestCase {
    struct Golden: Decodable {
        struct Segment: Decodable { let startSample: Int; let endSample: Int; let reason: String; let text: String; let inputSha256: String }
        struct Word: Decodable { let text: String; let startMs: Int64; let endMs: Int64 }
        let input: String; let inputSha256: String; let segments: [Segment]; let words: [Word]
    }
    private enum Failure: Error { case segmentInputMismatch }
    func testBothSharedGoldensWithThePinnedForkAndUnmodifiedModel() throws {
        let env = ProcessInfo.processInfo.environment
        guard let runtime = env["CASSINI_PARAKEET_RUNTIME"], let model = env["CASSINI_PARAKEET_MODEL"], let pipeline = env["CASSINI_PIPELINE_ASSETS"] else {
            throw XCTSkip("Pinned D16 runtime/model and D11 Silero assets supplied by Parakeet CI")
        }
        let assets = try ParakeetAssets.pinned(runtime:URL(fileURLWithPath:runtime),model:URL(fileURLWithPath:model))
        let engine = try ParakeetEngine(assets:assets)
        let detector = try SpeechDetector(assets:VADAssets.forWorker(arguments:["--assets",pipeline]))
        let root = Bundle.module.url(forResource:"Goldens",withExtension:nil)!
        let fixtures = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("CassiniTranscriptionTests/Goldens")
        let punctuation = Set<Character>([",",".","?","!"])
        func comparable(_ text: String) -> String { String(text.reversed().drop(while:{ punctuation.contains($0) }).reversed()) }
        func comparableText(_ text: String) -> [String] { text.split(separator:" ",omittingEmptySubsequences:false).map { comparable(String($0)) } }
        for name in ["parakeet-golden","parakeet-pipeline-golden"] {
            let golden = try JSONDecoder().decode(Golden.self,from:Data(contentsOf:root.appendingPathComponent(name + ".json")))
            let input = fixtures.appendingPathComponent(golden.input)
            let inputHash = SHA256.hash(data:try Data(contentsOf:input)).map { String(format:"%02x",$0) }.joined()
            XCTAssertEqual(inputHash,golden.inputSha256,name)
            let audio = try SegmentedAudio(url:input,detector:detector)
            let expectedSegments: [SpeechSegment] = golden.segments.map { SpeechSegment(startSample:$0.startSample,endSample:$0.endSample,reason:$0.reason) }
            XCTAssertEqual(audio.segments,expectedSegments,name)
            guard audio.segments.count == golden.segments.count else { throw Failure.segmentInputMismatch }
            var words: [(text:String,start:Int64,end:Int64)] = []
            for (segment,expected) in zip(audio.segments,golden.segments) {
                let samples = try audio.samples(segment)
                let data = samples.withUnsafeBytes { Data($0) }
                let hash = SHA256.hash(data:data).map { String(format:"%02x",$0) }.joined()
                // No time/text tolerance applies if the actual recognizer input
                // differs. Compare before invoking the native decoder.
                XCTAssertEqual(hash,expected.inputSha256,"\(name) segment \(segment.startSample)")
                guard hash == expected.inputSha256 else { throw Failure.segmentInputMismatch }
                let result = try engine.transcribe(samples:samples)
                XCTAssertEqual(result.language,"und")
                XCTAssertEqual(comparableText(result.text),comparableText(expected.text),name)
                let base = Int64(segment.startSample * 1000 / 16000)
                for word in result.words ?? [] {
                    let start = base + Int64((word.start * 1000).rounded(.toNearestOrAwayFromZero))
                    let end = base + Int64((word.end * 1000).rounded(.toNearestOrAwayFromZero))
                    words.append((word.word,start,end))
                }
                print("D16 \(name) segment \(segment.startSample) input \(hash): \(result.text)")
            }
            XCTAssertEqual(words.count,golden.words.count,name)
            for (index,pair) in zip(words,golden.words).enumerated() {
                XCTAssertEqual(comparable(pair.0.text),comparable(pair.1.text),"\(name) word \(index)")
                XCTAssertLessThanOrEqual(abs(pair.0.start - pair.1.startMs),80,"\(name) word \(index) start")
                XCTAssertLessThanOrEqual(abs(pair.0.end - pair.1.endMs),80,"\(name) word \(index) end")
            }
            print("D16 \(name): \(audio.segments.count) exact input segments, \(words.count) words, 80ms/punctuation policy")
        }
    }
}
