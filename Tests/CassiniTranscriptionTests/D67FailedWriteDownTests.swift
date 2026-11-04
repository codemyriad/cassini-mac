// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
import Foundation
import CassiniLibrary
import CassiniRecording
@testable import CassiniTranscription

/// D67.2: a failed write-down references no words; its partial transcript.json stays in the
/// folder, unreferenced, so no reader or published copy shows partial words as stored.
final class D67FailedWriteDownTests: XCTestCase {
    func testAFailedWriteDownStoresANullReferenceAndKeepsThePartialFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("D67Failed-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try RecordingSession(parent:root,title:"Failed",source:"chromium")
        try session.transition(starting:[.init(id:"guest",label:"Ana",kind:"remote",sampleRate:16000,channels:1,sourceTrackId:"ana")])
        try session.appendNative(id:"guest",pcm:Data(count:32000),offsetMs:0)
        try session.finish()
        let meeting = try XCTUnwrap(LibraryScanner(root:root).scan().meetings.first)
        // A running attempt has published partial words and references them.
        let partial = Data(#"{"language":"en","items":[{"speaker":"track-guest","startMs":0,"endMs":400,"text":"partial"}]}"#.utf8)
        try partial.write(to:session.directory.appendingPathComponent("transcript.json"))
        try MeetingMetadataWriter(directory:session.directory,id:meeting.id).transaction { metadata in
            metadata["transcript"] = ["status":"running","reference":["kind":"sidecar","file":"transcript.json","format":"cassini.words.v1"],"model":"whistle"]
        }
        XCTAssertFalse(try XCTUnwrap(LibraryScanner(root:root).scan().meetings.first).transcriptItems.isEmpty,"the running attempt shows its words")
        try MeetingTranscriber.setStatus(directory:session.directory,id:meeting.id,status:"failed")
        let stored = try JSONSerialization.jsonObject(with:Data(contentsOf:session.directory.appendingPathComponent("meeting.json"))) as? [String:Any]
        let transcript = try XCTUnwrap(stored?["transcript"] as? [String:Any])
        XCTAssertEqual(transcript["status"] as? String,"failed")
        XCTAssertTrue(transcript["reference"] is NSNull,"a failed write-down references no words")
        XCTAssertEqual(try Data(contentsOf:session.directory.appendingPathComponent("transcript.json")),partial,"the partial file stays, unreferenced")
        let failed = try XCTUnwrap(LibraryScanner(root:root).scan().meetings.first)
        XCTAssertEqual(failed.state.transcript,.failed)
        XCTAssertTrue(failed.transcriptItems.isEmpty,"no partial words are shown")
        // Try again is a fresh write-down: queued, still with no reference.
        try MeetingTranscriber.setStatus(directory:session.directory,id:meeting.id,status:"queued")
        let retried = try JSONSerialization.jsonObject(with:Data(contentsOf:session.directory.appendingPathComponent("meeting.json"))) as? [String:Any]
        XCTAssertTrue((retried?["transcript"] as? [String:Any])?["reference"] is NSNull)
    }
}
