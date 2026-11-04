// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
import Foundation
import CassiniLibrary
import CassiniRecording
import CassiniVAD
import CassiniWhistle
@testable import CassiniTranscription

/// D67.2 (#139 review): a failed write-down keeps its partial words in transcript.json,
/// unreferenced. Try again must not replace them until it has written as many words, so a retry
/// that fails before catching up keeps the longer snapshot; a completed retry replaces it.
final class D67RetryTranscriptionMeetingTests: XCTestCase {
    private struct Crash: Error {}
    private func words(_ count: Int) -> WhistleTranscript {
        let list = (0..<count).map { WhistleTranscript.Word(word:"w\($0)",start:Double($0)*0.2,end:Double($0)*0.2+0.1,probability:1) }
        return .init(text:list.map(\.word).joined(separator:" "),language:"en",words:list)
    }
    private func sidecar(_ directory: URL) throws -> [String] {
        let body = try JSONSerialization.jsonObject(with:Data(contentsOf:directory.appendingPathComponent("transcript.json"))) as? [String:Any]
        return (body?["items"] as? [[String:Any]] ?? []).compactMap { $0["text"] as? String }
    }
    private func transcript(_ directory: URL) throws -> [String:Any] {
        let stored = try JSONSerialization.jsonObject(with:Data(contentsOf:directory.appendingPathComponent("meeting.json"))) as? [String:Any]
        return try XCTUnwrap(stored?["transcript"] as? [String:Any])
    }
    func testARetryThatFailsBeforeCatchingUpKeepsTheLongerSnapshot() throws {
        guard let assets = ProcessInfo.processInfo.environment["CASSINI_PIPELINE_ASSETS"] else { throw XCTSkip("Pinned offline VAD supplied by pipeline CI") }
        let detector = try SpeechDetector(assets:(try? VADAssets.forWorker(arguments:["--assets",assets])) ?? VADAssets.pinned(directory:URL(fileURLWithPath:assets)))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("D67Retry-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let session = try RecordingSession(parent:root,title:"Retry",source:"chromium")
        try session.transition(starting:[.init(id:"speech",label:"Guest",kind:"remote",sampleRate:16000,channels:1,sourceTrackId:"guest")])
        let speech = Data(try Data(contentsOf:XCTUnwrap(Bundle.module.url(forResource:"jfk",withExtension:"wav",subdirectory:"Goldens"))).dropFirst(44))
        for start in stride(from:0,to:speech.count,by:80000) {
            try session.appendNative(id:"speech",pcm:speech.subdata(in:start..<min(speech.count,start + 80000)),offsetMs:Double(start / 2) / 16)
        }
        try session.finish()
        let directory = session.directory
        let id = try XCTUnwrap(LibraryScanner(root:root).scan().meetings.first).id
        // Attempt 1: the first speech segment yields three words, then the worker crashes.
        var calls = 0
        XCTAssertThrowsError(try MeetingTranscriber.run(directory:directory,detector:detector,model:"whistle",initialETA:0.15) { _ in
            calls += 1; if calls == 1 { return self.words(3) }; throw Crash()
        })
        XCTAssertGreaterThan(calls,1,"the crash came after published words")
        XCTAssertEqual(try transcript(directory)["status"] as? String,"failed"); XCTAssertTrue(try transcript(directory)["reference"] is NSNull)
        XCTAssertEqual(try sidecar(directory),["w0","w1","w2"],"the partial words are kept, unreferenced")
        XCTAssertEqual(LibraryScanner.sidecarWordCount(folder:directory),3)
        // Try again, which fails before catching up: one word, then a crash.
        try MeetingTranscriber.setStatus(directory:directory,id:id,status:"queued")
        calls = 0
        var visibleWhileBehind: [Int] = [], referenceWhileBehind: [Bool] = []
        XCTAssertThrowsError(try MeetingTranscriber.run(directory:directory,detector:detector,model:"whistle",initialETA:0.15) { _ in
            calls += 1
            // Running and behind the retained snapshot: the reader shows no words, and meeting.json
            // references none (the failed attempt's words never reappear under this attempt).
            visibleWhileBehind.append(try XCTUnwrap(LibraryScanner(root:root).scan().meetings.first).transcriptItems.count)
            referenceWhileBehind.append(try self.transcript(directory)["reference"] is NSNull)
            if calls == 1 { return self.words(1) }; throw Crash()
        })
        XCTAssertEqual(visibleWhileBehind,[0,0],"no words are visible before the retry catches up")
        XCTAssertEqual(referenceWhileBehind,[true,true])
        XCTAssertEqual(try transcript(directory)["status"] as? String,"failed")
        XCTAssertEqual(try sidecar(directory),["w0","w1","w2"],"a shorter failed retry never replaces the longer snapshot")
        // Try again, which completes: its words replace the snapshot, whatever their number.
        try MeetingTranscriber.setStatus(directory:directory,id:id,status:"queued")
        try MeetingTranscriber.run(directory:directory,detector:detector,model:"whistle",initialETA:0.15) { _ in self.words(1) }
        XCTAssertEqual(try transcript(directory)["status"] as? String,"done")
        let done = try XCTUnwrap(LibraryScanner(root:root).scan().meetings.first)
        XCTAssertEqual(done.transcriptItems.count,try sidecar(directory).count,"the completed retry's own words")
        XCTAssertFalse(done.transcriptItems.isEmpty)
    }
}
