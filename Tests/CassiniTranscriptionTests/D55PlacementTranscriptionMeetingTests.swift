// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
import Foundation
import CassiniLibrary
import CassiniRecording
import CassiniVAD
import CassiniWhistle
@testable import CassiniTranscription

/// D55 (M9): recognition places a track with the one placement (16 kHz), and an attempt
/// that assumed a zero offset says so in writingDown.offsetsAssumedZero.
final class D55PlacementTranscriptionMeetingTests: XCTestCase {
    /// One word per non-silent run, at its own time (GNOME RunModel).
    private func runModel(_ samples: [Float]) -> WhistleTranscript {
        var words: [WhistleTranscript.Word] = [], start: Int?, lastSound = 0
        for (i,value) in (samples + [Float](repeating:0,count:801)).enumerated() {
            if value != 0 { if start == nil { start = i }; lastSound = i; continue }
            if let s = start, i - lastSound > 800 {
                words.append(.init(word:"w\(words.count)",start:Double(s)/16000,end:Double(lastSound + 1)/16000,probability:1)); start = nil
            }
        }
        return .init(text:words.map(\.word).joined(separator:" "),language:"en",words:words)
    }
    private func detector() throws -> SpeechDetector {
        guard let assets = ProcessInfo.processInfo.environment["CASSINI_PIPELINE_ASSETS"] else { throw XCTSkip("Pinned offline VAD supplied by pipeline CI") }
        return try SpeechDetector(assets:(try? VADAssets.forWorker(arguments:["--assets",assets])) ?? VADAssets.pinned(directory:URL(fileURLWithPath:assets)))
    }
    /// 1 s of digital silence, then real speech (the bundled JFK golden, 16 kHz mono).
    private func meeting(_ root: URL, offsetMs: Double) throws -> RecordingSession {
        let session = try RecordingSession(parent:root,title:"Placement",source:"chromium")
        try session.transition(starting:[.init(id:"guest",label:"Guest",kind:"remote",sampleRate:16000,channels:1,sourceTrackId:"guest")])
        let speech = try Data(contentsOf:XCTUnwrap(Bundle.module.url(forResource:"jfk",withExtension:"wav",subdirectory:"Goldens"))).dropFirst(44).prefix(160000)
        try session.appendNative(id:"guest",pcm:Data(count:32000),offsetMs:offsetMs)
        try session.appendNative(id:"guest",pcm:Data(speech),offsetMs:offsetMs + 1000)
        try session.finish()
        return session
    }
    /// The track-local 16 kHz sample the first word marks: the first non-zero sample of the
    /// first VAD segment, from the same deterministic decode the transcriber uses.
    private func recognizedSample(_ root: URL, _ detector: SpeechDetector) throws -> Int {
        let track = try XCTUnwrap(LibraryScanner(root:root).scan().meetings.first?.audioTracks.first)
        let audio = try SegmentedAudio(url:track.url,detector:detector)
        let segment = try XCTUnwrap(audio.segments.first)
        return segment.startSample + (try XCTUnwrap(audio.samples(segment).firstIndex { $0 != 0 }))
    }
    private func writingDown(_ session: RecordingSession) throws -> [String:Any] {
        let stored = try JSONSerialization.jsonObject(with:Data(contentsOf:session.directory.appendingPathComponent("meeting.json"))) as? [String:Any]
        return try XCTUnwrap((stored?["recordingDetails"] as? [String:Any])?["writingDown"] as? [String:Any])
    }

    func testWordsArePlacedAtTheSharedPlacementSample() throws {
        let detector = try detector()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("D55Words-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let offset = 1234.97
        let session = try meeting(root,offsetMs:offset), local = try recognizedSample(root,detector)
        try MeetingTranscriber.run(directory:session.directory,detector:detector,model:"whistle",initialETA:0.15,recognize:runModel)
        let written = try XCTUnwrap(LibraryScanner(root:root).scan().meetings.first)
        let first = try XCTUnwrap(written.transcriptItems.first)
        let start = Int(TrackPlacement.frame(ms:offset,rate:16000))
        XCTAssertEqual(start,19760,"19759.52 rounds half away from zero")
        XCTAssertEqual(first.startMs,Int64(start + local) * 1000 / 16000,"the first word sits at the placement sample")
        XCTAssertEqual(Double(first.startMs),offset + Double(local) / 16,accuracy:20,"within 20 ms of its true session time")
        // The old placement (offset floored to whole ms) lands 1 ms early here; it must fail.
        XCTAssertNotEqual(first.startMs,Int64(offset.rounded(.down)) + Int64(local) * 1000 / 16000,"floored-offset placement")
        XCTAssertNil(try writingDown(session)["offsetsAssumedZero"],"a known offset assumes nothing")
    }
    func testAnUnknownOffsetIsPlacedAtZeroAndFlagged() throws {
        let detector = try detector()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("D55Assumed-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let session = try meeting(root,offsetMs:500), local = try recognizedSample(root,detector)
        // A salvaged manifest that lost the track's offset.
        let url = session.directory.appendingPathComponent("session.json")
        var manifest = try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:url)) as? [String:Any])
        var tracks = try XCTUnwrap(manifest["tracks"] as? [[String:Any]])
        tracks[0].removeValue(forKey:"startOffsetMs"); manifest["tracks"] = tracks
        try JSONSerialization.data(withJSONObject:manifest).write(to:url)
        try MeetingTranscriber.run(directory:session.directory,detector:detector,model:"whistle",initialETA:0.15,recognize:runModel)
        let written = try XCTUnwrap(LibraryScanner(root:root).scan().meetings.first)
        XCTAssertEqual(written.transcriptItems.first?.startMs,Int64(local) * 1000 / 16000,"placed at 0")
        XCTAssertEqual(try writingDown(session)["offsetsAssumedZero"] as? Bool,true)
    }
}
