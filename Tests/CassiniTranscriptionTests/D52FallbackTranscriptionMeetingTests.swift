// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
import Foundation
import CassiniLibrary
import CassiniRecording
import CassiniWhistle
@testable import CassiniTranscription

/// D52.4 R71 (M13) through the real MeetingTranscriber and pinned VAD: a track the
/// VAD rejects but that holds plenty of active audio is written down by the
/// windowed fallback, once, with provenance; a short track streams unheld.
final class D52FallbackTranscriptionMeetingTests: XCTestCase {
    private let rate = 16000
    /// Speech-like bursts on even seconds (0.2 s quiet onset, 0.8 s loud tone); odd seconds silent.
    private func bursts(_ seconds: Int) -> [Float] {
        (0..<(seconds*rate)).map { i in
            let second = i / rate, within = i % rate
            guard second % 2 == 0 else { return 0 }
            let level = within < rate/5 ? 0.02 : 0.25
            return Float(level * sin(2 * .pi * 300 * Double(i) / Double(rate)))
        }
    }
    /// One word per non-silent run, at the run's own window-relative time (GNOME RunModel).
    /// Int16 quantization leaves isolated zeros at sine zero crossings, so only 50 ms of
    /// silence ends a run.
    private func runModel(_ samples: [Float]) -> WhistleTranscript {
        var words: [WhistleTranscript.Word] = [], start: Int?, lastSound = 0
        for (i,value) in (samples + [Float](repeating:0,count:801)).enumerated() {
            if value != 0 { if start == nil { start = i }; lastSound = i; continue }
            if let s = start, i - lastSound > 800 {
                words.append(.init(word:"w\(words.count)",start:Double(s)/Double(rate),end:Double(lastSound + 1)/Double(rate),probability:1)); start = nil
            }
        }
        return .init(text:words.map(\.word).joined(separator:" "),language:"en",words:words)
    }
    private func meeting(_ samples: [Float]) throws -> (URL,RecordingSession) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("D52Fallback-"+UUID().uuidString)
        let session = try RecordingSession(parent:root,title:"Fallback",source:"chromium")
        try session.transition(starting:[.init(id:"one",label:"Guest",kind:"remote",sampleRate:rate,channels:1,sourceTrackId:"guest")])
        let pcm = samples.map { Int16(max(-1,min(1,$0)) * 32767) }
        for start in stride(from:0,to:pcm.count,by:80000) {
            let chunk = Array(pcm[start..<min(pcm.count,start+80000)])
            try session.appendNative(id:"one",pcm:chunk.withUnsafeBytes { Data($0) },offsetMs:Double(start)/16)
        }
        try session.finish()
        return (root,session)
    }
    private func detector() throws -> SpeechDetector {
        guard let assets = ProcessInfo.processInfo.environment["CASSINI_PIPELINE_ASSETS"] else { throw XCTSkip("Pinned offline VAD supplied by pipeline CI") }
        // The pinned VAD (checksum-verified model and runtime) is all this test needs.
        return try SpeechDetector(assets:(try? VADAssets.forWorker(arguments:["--assets",assets])) ?? VADAssets.pinned(directory:URL(fileURLWithPath:assets)))
    }
    private func fallback(_ session: RecordingSession) throws -> [String:Any]? {
        let stored = try JSONSerialization.jsonObject(with:Data(contentsOf:session.directory.appendingPathComponent("meeting.json"))) as? [String:Any]
        return ((stored?["recordingDetails"] as? [String:Any])?["writingDown"] as? [String:Any])?["recognitionFallback"] as? [String:Any]
    }

    func testAVADRejectedActiveTrackIsWrittenDownByTheFallbackOnce() throws {
        let detector = try detector()
        let (root,session) = try meeting(bursts(40)); defer { try? FileManager.default.removeItem(at:root) }
        try MeetingTranscriber.run(directory:session.directory,detector:detector,model:"whistle",initialETA:0.15,recognize:runModel)
        let written = try XCTUnwrap(LibraryScanner(root:root).scan().meetings.first)
        let record = try XCTUnwrap(try fallback(session))
        XCTAssertEqual(record["method"] as? String,"vadFreeWindows"); XCTAssertEqual(record["windowMs"] as? Int,15000); XCTAssertEqual(record["overlapMs"] as? Int,500)
        let track = try XCTUnwrap((record["tracks"] as? [[String:Any]])?.first)
        XCTAssertEqual(track["trackId"] as? String,"one"); XCTAssertEqual(track["activeSeconds"] as? Double,16.64)
        let vad = try XCTUnwrap(track["vadWords"] as? Int)
        XCTAssertLessThan(vad,RecognitionFallback.fewWords)
        XCTAssertEqual(track["fallbackWords"] as? Int,20,"one word per burst; the seam keeps one copy")
        XCTAssertEqual(track["used"] as? Bool,20 >= RecognitionFallback.need(vad))
        if track["used"] as? Bool == true {
            XCTAssertEqual(written.transcriptItems.count,20)
            // Each burst's word lies on its own audio, never duplicated across a window seam.
            let starts = written.transcriptItems.map(\.startMs)
            XCTAssertEqual(starts,starts.sorted()); XCTAssertEqual(Set(starts).count,20)
            XCTAssertTrue(written.transcriptItems.allSatisfy { ($0.startMs / 1000) % 2 == 0 })
        }
    }
    func testAShortActiveTrackStreamsWithoutTheFallback() throws {
        let detector = try detector()
        let (root,session) = try meeting(bursts(10)); defer { try? FileManager.default.removeItem(at:root) }
        try MeetingTranscriber.run(directory:session.directory,detector:detector,model:"whistle",initialETA:0.15,recognize:runModel)
        XCTAssertNil(try fallback(session),"no track met the gate, so no provenance")
    }
}
