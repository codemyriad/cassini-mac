// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
import Foundation
import CassiniKit
import CassiniLibrary
import CassiniVAD
import CassiniWhistle
@testable import CassiniTranscription

/// D52 M17: the whole write-down (real pinned VAD, M13 fallback, M15 scratch) on the
/// shared production-shaped corpus. A run model stands in for the recognizer: one word
/// per non-silent run, at its own time, so every word marks audio that was recognized.
final class D52CorpusTranscriptionMeetingTests: XCTestCase {
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
    func testEveryWordLiesInItsSpeakersRecognizedTime() throws {
        guard let assets = ProcessInfo.processInfo.environment["CASSINI_PIPELINE_ASSETS"] else { throw XCTSkip("Pinned offline VAD supplied by pipeline CI") }
        let detector = try SpeechDetector(assets:(try? VADAssets.forWorker(arguments:["--assets",assets])) ?? VADAssets.pinned(directory:URL(fileURLWithPath:assets)))
        let root = try D52CorpusTests.materialize(); defer { try? FileManager.default.removeItem(at:root) }
        let before = try XCTUnwrap(try LibraryScanner(root:root).scan().meetings.first { $0.audioTracks.count == 8 })
        try MeetingTranscriber.run(directory:before.folder,detector:detector,model:"whistle",initialETA:0.15,recognize:runModel)
        let meeting = try XCTUnwrap(try LibraryScanner(root:root).scan().meetings.first { $0.id == before.id })
        XCTAssertEqual(meeting.state.transcript,.done)
        // Speakers as the transcriber assigns them: one lane per source while its spans are disjoint.
        func base(_ track: LibraryAudioTrack) -> String {
            TranscriptSpeaker.fromTrack(id:track.sourceID ?? "",kind:track.sourceKind ?? "media",sourceTrackID:track.sourceTrackID).id
        }
        let lanes = SourceSpanLanes.assign(meeting.audioTracks.compactMap { track in
            guard base(track).hasPrefix("track-"), let id = track.sourceID else { return nil }
            return .init(id:id,base:base(track),startMs:track.startOffsetMs,endMs:track.endOffsetMs)
        })
        let ownership = OthersOwnership(events:meeting.captureEvents)
        var windows: [String:[(Double,Double)]] = [:]
        for track in meeting.audioTracks {
            let offset = try XCTUnwrap(track.startOffsetMs), frames = try XCTUnwrap(track.frameCount), rate = try XCTUnwrap(track.sampleRate)
            let count = Int(frames * 16000 / UInt64(rate)), kind = track.sourceKind ?? "media"
            let owned = MeetingTranscriber.ownedWindows(offsetMs:offset,sampleCount:count,kind:kind,gaps:MeetingTranscriber.presenceGaps(track),ownership:ownership)
                ?? [(offset,offset + Double(count)/16)]
            windows[lanes[track.sourceID ?? ""] ?? base(track),default:[]] += owned
        }
        XCTAssertEqual(Set(meeting.transcriptItems.map(\.speaker)).subtracting(windows.keys),[],"no word from an unknown speaker")
        XCTAssertTrue(meeting.transcriptItems.contains { $0.speaker == "track-source-a" },"the late, sparse source is written down")
        for item in meeting.transcriptItems {
            let mid = Double(item.startMs + item.endMs) / 2
            XCTAssertTrue(windows[item.speaker]?.contains { mid >= $0.0 - 40 && mid < $0.1 + 40 } == true,
                          "\(item.speaker) word at \(item.startMs)–\(item.endMs) ms is outside its recognized time")
        }
    }
}
