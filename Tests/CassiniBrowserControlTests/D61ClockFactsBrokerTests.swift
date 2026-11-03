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

    /// #132 review: every later span of a browser source repeats its clock facts. A stand-in is
    /// joined by a resumed browser whose track declares them; restoreBrowser (browser audio
    /// replacing the system stand-in) starts one span, and turning Others off and on again
    /// starts another. Every remote span keeps all three facts, in session.json and in the
    /// capture record.
    func testRestoredAndReselectedSpansKeepTheirClockFacts() async throws {
        let fixture = try AudioFixture()
        do {
            let origin = 1793500000000
            let capture = try OwnedBrowserCapture(parent:fixture.root.appendingPathComponent("Library"),title:"Stand-in",microphone:true,browser:false,changed:{ _ in })
            let system = capture.nativeWriter(side:.others)
            try system.addTrack(id:"output",label:"Others",kind:"system",sampleRate:8000,channels:1)
            try system.appendNative(id:"output",pcm:Data(repeating:0,count:1600),offsetMs:0)
            try fixture.broker.ownNative(capture,timelineOriginMs:origin)
            let id = try XCTUnwrap(fixture.broker.standInIdentity(capture)).captureID
            fixture.broker.expectResume(capture,callGeneration:"call-A")
            let client = try fixture.client()
            XCTAssertEqual(try client.request(["type":"resume","version":1,"independent":true,"captureId":id,"timelineOriginMs":origin,"callGeneration":"call-A",
                                               "features":["source-outcomes-v1","resume-capture-v1"]])["type"]?.string,"started")
            XCTAssertEqual(try client.request(["type":"track","id":"r1","kind":"remote","label":"Guest","sampleRate":8000,"channels":1,"sourceTrackId":"guest",
                                               "clockMethod":"roundTrip","clockUncertaintyMs":12,"clockClampMs":3])["type"]?.string,"ack")
            XCTAssertEqual(try client.request(["type":"audio","id":"r1","sequence":0,"offsetMs":0,"pcm":Data(repeating:1,count:16000).base64EncodedString()])["type"]?.string,"ack")
            try await capture.restoreBrowser(atMs:6000)                        // the restore path
            try await capture.select(me:true,others:false,atMs:7000)
            try await capture.select(me:true,others:true,atMs:8000)            // the selection path
            XCTAssertEqual(try client.request(["type":"audio","id":"r1","sequence":1,"offsetMs":8100,"pcm":Data(repeating:1,count:1600).base64EncodedString()])["type"]?.string,"ack")
            XCTAssertEqual(try client.request(["type":"stop","captureId":id])["type"]?.string,"stopped")
            let folder = capture.snapshot.directory
            let session = try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:folder.appendingPathComponent("session.json"))) as? [String:Any])
            let spans = ((session["tracks"] as? [[String:Any]]) ?? []).filter { $0["kind"] as? String == "remote" }
            XCTAssertGreaterThanOrEqual(spans.count,2,"a restored span and a reselected one")
            for span in spans {
                XCTAssertEqual(span["clockMethod"] as? String,"roundTrip"); XCTAssertEqual(span["clockUncertaintyMs"] as? Int,12); XCTAssertEqual(span["clockClampMs"] as? Int,3)
            }
            let meeting = try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:folder.appendingPathComponent("meeting.json"))) as? [String:Any])
            let record = (((meeting["recordingDetails"] as? [String:Any])?["captureRecord"] as? [String:Any])?["tracks"] as? [[String:Any]] ?? []).filter { $0["kind"] as? String == "remote" }
            XCTAssertEqual(record.count,spans.count)
            for span in record { XCTAssertEqual(span["clockMethod"] as? String,"roundTrip"); XCTAssertEqual(span["clockClampMs"] as? Int,3) }
        } catch { await fixture.finish(); throw error }
        await fixture.finish()
    }
}
