// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
import Foundation
import CassiniKit
import CassiniLibrary
import CassiniRecording
@testable import CassiniBrowserControl

/// D52.1 R65/R69: recordingDetails.captureRecord v1 in meeting.json.
final class D52CaptureRecordTests: XCTestCase, @unchecked Sendable {
    private func meeting(_ folder: URL) throws -> [String:Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:folder.appendingPathComponent("meeting.json"))) as? [String:Any])
    }
    func testFinalizationWritesTheRecordWithEveryAnnouncedSourceAndNoPaths() async throws {
        let fixture = try AudioFixture()
        do {
            let client = try fixture.client()
            let started = try client.request(["type":"start","version":1,"independent":true,"captureId":"record","timelineOriginMs":Int(Date().timeIntervalSince1970*1000),
                                              "microphone":false,"title":"Call","features":["source-outcomes-v1"]])
            XCTAssertEqual(try client.request(["type":"track","id":"a","kind":"remote","label":"Guest","sampleRate":8000,"channels":1,"sourceTrackId":"guest"])["type"]?.string,"ack")
            XCTAssertEqual(try client.request(["type":"audio","id":"a","sequence":0,"offsetMs":0,"pcm":Data(repeating:1,count:16000).base64EncodedString()])["type"]?.string,"ack")
            XCTAssertEqual(try client.request(["type":"stop","captureId":"record","discoveredSources":[["sourceTrackId":"never","kind":"remote","label":"Host","failed":true]]])["type"]?.string,"stopped")
            let folder = URL(fileURLWithPath:try XCTUnwrap(started["path"]?.string))
            let record = try XCTUnwrap((try meeting(folder)["recordingDetails"] as? [String:Any])?["captureRecord"] as? [String:Any])
            XCTAssertEqual(record["version"] as? Int,1)
            let sources = try XCTUnwrap(record["sources"] as? [[String:Any]])
            XCTAssertEqual(sources.compactMap { $0["sourceTrackId"] as? String },["guest","never"])
            XCTAssertEqual(sources.compactMap { $0["captureOutcome"] as? String },["captured","failed"])
            let tracks = try XCTUnwrap(record["tracks"] as? [[String:Any]])
            XCTAssertEqual(tracks.count,1); XCTAssertNil(tracks[0]["file"]); XCTAssertEqual(tracks[0]["receivedFrames"] as? Int,8000)
            XCTAssertEqual(record["problemKind"] as? String,"capture")
            XCTAssertFalse(String(decoding:try Data(contentsOf:folder.appendingPathComponent("meeting.json")),as:UTF8.self).contains(folder.path))
            // An identical rewrite keeps the revision.
            let revision = try meeting(folder)["revision"] as? Int
            try CaptureRecordWriter.write(try RecordingLoader.load(directory:folder),directory:folder)
            XCTAssertEqual(try meeting(folder)["revision"] as? Int,revision)
        } catch { await fixture.finish(); throw error }
        await fixture.finish()
    }
    func testMergeKeepsUnknownFieldsReplacesExpectationAndNeverDowngrades() {
        let stored: [String:Any] = ["version":1,"future":true,
            "sources":[["sourceTrackId":"a","captureOutcome":"neverAudio","captureExpected":false,"extra":1]],
            "tracks":[["id":"t","frames":1,"note":"keep"]],"events":[]]
        let fresh: [String:Any] = ["version":1,"sources":[["sourceTrackId":"a","captureOutcome":"captured"],["sourceTrackId":"b","captureOutcome":"failed"]],
            "tracks":[["id":"t","frames":2]],"events":[["type":"end"]]]
        let merged = CaptureRecordWriter.merge(stored,fresh)!
        XCTAssertEqual(merged["future"] as? Bool,true)
        let sources = merged["sources"] as! [[String:Any]]
        XCTAssertEqual(sources.count,2); XCTAssertEqual(sources[0]["captureOutcome"] as? String,"captured")
        XCTAssertNil(sources[0]["captureExpected"],"captureExpected is replaced, not merged"); XCTAssertEqual(sources[0]["extra"] as? Int,1)
        XCTAssertEqual((merged["tracks"] as! [[String:Any]])[0]["note"] as? String,"keep")
        XCTAssertEqual((merged["tracks"] as! [[String:Any]])[0]["frames"] as? Int,2)
        XCTAssertNil(CaptureRecordWriter.merge(["version":2,"sources":[]],fresh),"A newer record is left untouched")
    }
}
