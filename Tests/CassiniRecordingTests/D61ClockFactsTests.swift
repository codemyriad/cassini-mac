// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
import Foundation
import CassiniKit
@testable import CassiniRecording

/// D61 (protocol #39): a browser track's three clock facts are copied into session.json as
/// received, each omitted when absent or invalid; documentGeneration is never written.
final class D61ClockFactsTests: XCTestCase {
    private func json(_ value: Any) throws -> JSON { try JSONParser.parse(JSONSerialization.data(withJSONObject:value)) }
    private func track(_ manifest: URL, _ id: String) throws -> [String:Any] {
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:manifest.appendingPathComponent("session.json"))) as? [String:Any])
        return try XCTUnwrap((root["tracks"] as? [[String:Any]])?.first { $0["id"] as? String == id })
    }

    /// The three D61 clock vectors in conformance/vectors.json, through the legacy host:
    /// the facts copied as received, invalid ones omitted one by one (9.0 and 1e3 are not
    /// integer facts), never cross-checked, and documentGeneration never written.
    func testTheSharedVectorsCopyTheFactsAndNeverTheGeneration() throws {
        let url = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("browser-protocol/conformance/vectors.json")
        let all = try XCTUnwrap(try JSONParser.parse(Data(contentsOf:url)).array)
        let names = ["track-clock-and-document-fields","track-invalid-clock-facts-are-omitted","track-clock-facts-are-not-cross-checked"]
        for name in names {
            let vector = try XCTUnwrap(all.first { $0["name"]?.string == name },name)
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("D61-"+UUID().uuidString); defer { try? FileManager.default.removeItem(at:root) }
            let host = BrowserRecordingHost { title in try RecordingSession(parent:root,title:title,source:"chromium") }
            let replies = try vector["requests"]!.array!.map { try host.receive(Data($0.string!.utf8))["type"] }
            XCTAssertEqual(replies,vector["expect"]!.array!.map { $0["type"]?.string },name)
            let directory = try XCTUnwrap(host.session).directory
            XCTAssertEqual(try RecordingLoader.load(directory:directory).state,vector["state"]?.string,name)
            let tracks = try XCTUnwrap(vector["tracks"]?.object,name)
            XCTAssertFalse(tracks.isEmpty,name)
            for (id,want) in tracks {
                let stored = try track(directory,id)
                XCTAssertEqual(stored["clockMethod"] as? String,want["clockMethod"]?.string,"\(name) \(id)")
                XCTAssertEqual(stored["clockUncertaintyMs"] as? Int,want["clockUncertaintyMs"]?.int,"\(name) \(id)")
                XCTAssertEqual(stored["clockClampMs"] as? Int,want["clockClampMs"]?.int,"\(name) \(id)")
                XCTAssertNil(stored["documentGeneration"],"documentGeneration is a liveness hint, never written")
            }
        }
    }
    /// Each fact stands on its own: an invalid one is omitted, the valid ones are kept.
    func testInvalidFactsAreOmittedOneByOne() throws {
        XCTAssertNil(ClockFacts.parse(try json(["clockMethod":"other","clockUncertaintyMs":-1,"clockClampMs":0])))
        for bad: Any in [1.5,"9",86400001,true,NSNull()] {
            XCTAssertNil(ClockFacts.parse(try json(["clockUncertaintyMs":bad])),"\(bad)")
        }
        XCTAssertNil(ClockFacts.parse(try JSONParser.parse(Data(#"{"clockUncertaintyMs":1e3}"#.utf8))),"An exponent is not an integer literal")
        XCTAssertEqual(ClockFacts.parse(try json(["clockMethod":"outputTimestamp","clockUncertaintyMs":1.5,"clockClampMs":86400000])),
                       ClockFacts(method:"outputTimestamp",clampMs:86400000))
        XCTAssertEqual(ClockFacts.parse(try json(["clockUncertaintyMs":0])),ClockFacts(uncertaintyMs:0))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("D61-"+UUID().uuidString); defer { try? FileManager.default.removeItem(at:root) }
        let host = BrowserRecordingHost { title in try RecordingSession(parent:root,title:title,source:"chromium") }
        _ = try host.receive(Data(#"{"type":"start"}"#.utf8))
        XCTAssertEqual(try host.receive(Data(#"{"type":"track","id":"x","kind":"remote","sampleRate":48000,"channels":1,"clockMethod":"guess","clockUncertaintyMs":4,"clockClampMs":-2}"#.utf8))["type"],"ack")
        XCTAssertEqual(try host.receive(Data(#"{"type":"track","id":"y","kind":"remote","sampleRate":48000,"channels":1}"#.utf8))["type"],"ack")
        _ = try host.receive(Data(#"{"type":"stop"}"#.utf8))
        let directory = try XCTUnwrap(host.session).directory
        let x = try track(directory,"x"), y = try track(directory,"y")
        XCTAssertNil(x["clockMethod"]); XCTAssertEqual(x["clockUncertaintyMs"] as? Int,4); XCTAssertNil(x["clockClampMs"])
        XCTAssertTrue(["clockMethod","clockUncertaintyMs","clockClampMs"].allSatisfy { y[$0] == nil },"An older extension's track carries none")
        // A reader treats stored invalid values as unknown.
        let loaded = try RecordingLoader.load(directory:directory)
        XCTAssertEqual(loaded.tracks.first { $0.id == "x" }?.clockUncertaintyMs,4)
    }
}
