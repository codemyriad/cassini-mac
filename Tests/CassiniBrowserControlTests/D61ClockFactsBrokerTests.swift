// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
import Foundation
import CassiniKit
import CassiniRecording
@testable import CassiniBrowserControl

/// D61 through the real host and app broker: an independent browser track's clock facts reach
/// its session.json span and the meeting.json capture record; documentGeneration reaches neither.
final class D61ClockFactsBrokerTests: XCTestCase {
    func testIndependentTrackFactsReachTheSpanAndTheRecord() async throws {
        let fixture = try AudioFixture()
        do {
            let client = try fixture.client()
            let started = try client.request(["type":"start","version":1,"independent":true,"captureId":"clock","timelineOriginMs":Int(Date().timeIntervalSince1970*1000),
                                              "microphone":false,"title":"Call","features":["source-outcomes-v1"]])
            XCTAssertEqual(try client.request(["type":"track","id":"a","kind":"remote","label":"Guest","sampleRate":8000,"channels":1,"sourceTrackId":"guest",
                                               "clockMethod":"roundTrip","clockUncertaintyMs":12,"clockClampMs":3,"documentGeneration":"doc-1"])["type"]?.string,"ack")
            XCTAssertEqual(try client.request(["type":"audio","id":"a","sequence":0,"offsetMs":0,"pcm":Data(repeating:1,count:1600).base64EncodedString()])["type"]?.string,"ack")
            XCTAssertEqual(try client.request(["type":"stop","captureId":"clock","discoveredSources":[]])["type"]?.string,"stopped")
            let folder = URL(fileURLWithPath:try XCTUnwrap(started["path"]?.string))
            let session = try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:folder.appendingPathComponent("session.json"))) as? [String:Any])
            let span = try XCTUnwrap((session["tracks"] as? [[String:Any]])?.first { $0["kind"] as? String == "remote" })
            XCTAssertEqual(span["clockMethod"] as? String,"roundTrip"); XCTAssertEqual(span["clockUncertaintyMs"] as? Int,12); XCTAssertEqual(span["clockClampMs"] as? Int,3)
            XCTAssertNil(span["documentGeneration"])
            let meeting = try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:folder.appendingPathComponent("meeting.json"))) as? [String:Any])
            let record = try XCTUnwrap(((meeting["recordingDetails"] as? [String:Any])?["captureRecord"] as? [String:Any])?["tracks"] as? [[String:Any]])
            let mirrored = try XCTUnwrap(record.first { $0["kind"] as? String == "remote" })
            XCTAssertEqual(mirrored["clockMethod"] as? String,"roundTrip"); XCTAssertEqual(mirrored["clockClampMs"] as? Int,3)
            XCTAssertNil(mirrored["documentGeneration"])
        } catch { await fixture.finish(); throw error }
        await fixture.finish()
    }
}
