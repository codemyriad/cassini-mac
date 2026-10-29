// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
import CryptoKit
import CassiniWhistle
import CassiniVAD
@testable import CassiniTranscription

final class DCSpeechPipelineTests: XCTestCase {
    private var dc: URL { Bundle.module.url(forResource:"Fixtures",withExtension:nil)!.appendingPathComponent("DC") }
    private func samples(_ name: String) throws -> [Float] {
        var resampler = try MeetingResampler(rate:48000), output: [Float] = []
        try MeetingAudioDecoder.decode(dc.appendingPathComponent(name + ".wav")) { pcm, rate in
            XCTAssertEqual(rate,48000); output += resampler.feed(pcm)
        }
        output += resampler.feed([],final:true); return output
    }
    private func assets() throws -> VADAssets {
        let env = ProcessInfo.processInfo.environment
        guard let folder = env["CASSINI_DC_ASSETS"] ?? env["CASSINI_PIPELINE_ASSETS"] else { throw XCTSkip("Pinned Silero assets supplied by speech CI") }
        return try VADAssets.pinned(directory:URL(fileURLWithPath:folder))
    }
    private var expected: [SpeechSegment] {
        [(105984,189440),(347648,367616),(371200,413184),(416256,458240),(504320,544256),(547328,589312)].map { .init(startSample:$0.0,endSample:$0.1,reason:"silence") }
    }
    func testD26FilteredSpeechAndControlHaveExactSegments() throws {
        let detector = try SpeechDetector(assets:assets())
        for name in ["dc-quiet-jfk-v1","dc-quiet-jfk-v1-control"] {
            detector.reset(); var gate = SpeechGate()
            var maximum: Float = 0, voiced = 0, frames = 0
            let pcm = try samples(name)
            var segments = try gate.feed(pcm) { frame in
                let value = try detector.probability(frame)
                maximum = max(maximum,value); voiced += value >= 0.5 ? 1 : 0; frames += 1
                return value
            }
            segments += gate.flush(); XCTAssertEqual(segments,expected,name)
            if name == "dc-quiet-jfk-v1" {
                XCTAssertEqual(frames,1181); XCTAssertLessThanOrEqual(abs(voiced-251),2)
                XCTAssertEqual(maximum,0.718,accuracy:0.01)
                print("D26 filtered: frames=\(frames) voiced=\(voiced) max=\(maximum)")
            }
            let audio = try SegmentedAudio(url:dc.appendingPathComponent(name + ".wav"),detector:detector)
            XCTAssertEqual(audio.segments,expected)
            for segment in audio.segments {
                // The recognition scratch must still contain exactly raw FIR samples.
                XCTAssertEqual(try audio.samples(segment),Array(pcm[segment.startSample..<segment.endSample]))
            }
        }
    }
    func testD26ExactBinary64FilterHashesAndStreamingState() throws {
        for (name,inputHash,filteredHash) in [
            ("dc-quiet-jfk-v1","071f051241d394587c85463272e9414f133ee18c4bb835d1382b662e4154efda","eeaeee543bc328acf6f0c4557e8aba86652e0144d9763264e1e5d62a3d13f968"),
            ("dc-quiet-jfk-v1-control","e31ed958621a39baf1d33dab6d10798695b8319e78fcaa1cb672cdb43c5f7830","6ece4c5cacfc2456cb79d0aa1b16f4aa3912fef6697912e633886d7b0da545ab")
        ] {
            XCTAssertEqual(SHA256.hash(data:try Data(contentsOf:dc.appendingPathComponent(name + ".wav"))).map { String(format:"%02x",$0) }.joined(),inputHash)
            let raw = try samples(name)
            // The final 128 FIR samples never form a Silero frame. Assert d
            // hashes only the complete 512-frame inputs actually sent to VAD.
            let pcm = Array(raw.prefix(raw.count/512*512)); var filter = SileroInputHighPass()
            let filtered = filter.process(pcm)
            XCTAssertEqual(filtered.count,604672)
            let hash = filtered.withUnsafeBytes { SHA256.hash(data:$0).map { String(format:"%02x",$0) }.joined() }
            XCTAssertEqual(hash,filteredHash,name)
            if name == "dc-quiet-jfk-v1" { XCTAssertEqual(Array(filtered.prefix(3)),[-0.039744045585393906,-0.06441963464021683,-0.05248776078224182]) }
            filter = .init(); var chunks: [Float] = []
            for at in stride(from:0,to:pcm.count,by:512) { chunks += filter.process(Array(pcm[at..<min(pcm.count,at+512)])) }
            XCTAssertEqual(chunks,filtered)
        }
    }
    func testD26UnfilteredFailureAndReset() throws {
        let files = try assets(); try WhistleEnvironment.validateLive()
        var error = [CChar](repeating:0,count:2048)
        let raw = try XCTUnwrap(cassini_vad_create(files.library.path,files.model.path,&error,error.count))
        defer { cassini_vad_destroy(raw) }
        var gate = SpeechGate(), maximum: Float = 0
        let pcm = try samples("dc-quiet-jfk-v1")
        var segments = try gate.feed(pcm) { frame in
            var value: Float = 0
            guard cassini_vad_probability(raw,frame,&value,&error,error.count) == 1 else { throw TranscriptionFailure.runtime(String(cString:error)) }
            maximum = max(maximum,value); return value
        }
        segments += gate.flush(); XCTAssertTrue(segments.isEmpty); XCTAssertLessThan(maximum,0.1)
        print("D26 unfiltered: max=\(maximum), segments=\(segments.count)")
        let detector = try SpeechDetector(assets:files), frame = Array(pcm.prefix(512))
        let first = try detector.probability(frame)
        _ = try detector.probability(Array(pcm[512..<1024]))
        detector.reset(); XCTAssertEqual(try detector.probability(frame),first)
        XCTAssertEqual(SpeechDetector.inputFilterVersion,"silero-input-hpf-butter2-100hz-v1")
    }
}
