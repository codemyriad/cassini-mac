import Foundation
import CryptoKit
import Testing
@testable import CassiniLibrary

/// S-3a expectations were independently reviewed before this adapter ran.
/// It calls the production scanner; no parallel derivation logic blesses output.
@Suite struct LibrarySharedVectorTests {
    @Test func allPublishedLibraryTrees() throws {
        let source = try #require(Bundle.module.url(forResource: "LibraryVectors", withExtension: nil))
        let pin = try JSONSerialization.jsonObject(with: Data(contentsOf: source.appendingPathComponent("UPSTREAM.json"))) as! [String: Any]
        for (name, expected) in pin["sha256"] as! [String: String] {
            let data = try Data(contentsOf: source.appendingPathComponent(name))
            let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            try #require(actual == expected, "Changed shared input/expectation: \(name)")
        }
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: source.appendingPathComponent("cases.json"))) as! [String: Any]
        let cases = manifest["cases"] as! [[String: Any]]
        let ids = Set(cases.map { $0["id"] as! String })
        let timeFile = try #require(Bundle.module.url(forResource:"MeetingTimeExpectations",withExtension:"json"))
        let timeExpectations = try JSONSerialization.jsonObject(with:Data(contentsOf:timeFile)) as! [String:Any]
        let creationOnly = timeExpectations["creationOnlyReceived"] as! [String:[String]]
        // 13 S-3a cases plus the 9 of shared test 8 (D67).
        try #require(cases.count == 22 && ids.count == 22)
        try #require(ids.contains("main") && Set(cases.flatMap { $0["rules"] as! [String] }).isSuperset(of: (1...9).map { "R\($0)" }))
        let expectedFiles = try FileManager.default.contentsOfDirectory(atPath: source.appendingPathComponent("expected").path)
        try #require(Set(expectedFiles.filter { $0.hasSuffix(".json") }.map { String($0.dropLast(5)) }) == ids)
        let now = Date(timeIntervalSince1970: (manifest["nowMs"] as! NSNumber).doubleValue / 1000)
        let format = LibraryFormat(timeZone: try #require(TimeZone(identifier: manifest["tz"] as! String)), now: now,locale:Locale(identifier:"en_GB"),language:.en)
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("cassini-shared-library-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: output) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", "-B", source.appendingPathComponent("make.py").path, output.path]
        try process.run(); process.waitUntilExit()
        try #require(process.terminationReason == .exit && process.terminationStatus == 0)
        let results = ProcessInfo.processInfo.environment["CASSINI_LIBRARY_RESULTS"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        if let results { try FileManager.default.createDirectory(at: results, withIntermediateDirectories: true) }
        for id in ids.sorted() {
            let directory = output.appendingPathComponent(id)
            let activity = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: directory.appendingPathComponent("activity.json")))
            var phases: [UUID: CaptureActivity] = [:]
            for (id, phase) in activity {
                let uuid = try #require(UUID(uuidString: id))
                try #require(["recording", "saving"].contains(phase))
                phases[uuid] = phase == "recording" ? .recording : .saving
            }
            let scanner = LibraryScanner(root: directory.appendingPathComponent("root"), activity: CaptureActivitySnapshot(phases))
            let actual: [String: Any]
            do {
                let scan = try scanner.scan(now: now)
                actual = ["scan": scan.meetings.isEmpty ? "empty" : "ok", "groups": scan.groups(format: format).map { group in
                    ["title": group.title, "meetings": group.meetings.map(Self.row)] as [String: Any]
                }]
            } catch {
                actual = ["scan": "failed", "groups": []]
            }
            let originalExpected = try JSONSerialization.jsonObject(with: Data(contentsOf: source.appendingPathComponent("expected/\(id).json")))
            let expected = Self.d95Expectation(originalExpected,creationOnly:Set(creationOnly[id] ?? []))
            let actualData = try JSONSerialization.data(withJSONObject: actual, options: [.sortedKeys, .prettyPrinted])
            let expectedData = try JSONSerialization.data(withJSONObject: expected, options: [.sortedKeys, .prettyPrinted])
            if let results {
                try actualData.write(to: results.appendingPathComponent("\(id).actual.json"))
                try expectedData.write(to: results.appendingPathComponent("\(id).expected.json"))
            }
            #expect(String(decoding: actualData, as: UTF8.self) == String(decoding: expectedData, as: UTF8.self), "S-3a \(id)")
            print("S-3a \(id): compared exact scan/groups/meeting fields")
        }
    }
    /// Explicit D95 deltas to the frozen S-3a oracle, not output-derived expectations.
    /// Preserve order within each day and every non-time field; unknown dates form one trailing group.
    private static func d95Expectation(_ original: Any, creationOnly: Set<String>) -> Any {
        guard !creationOnly.isEmpty else { return original }
        var expected = original as! [String:Any], groups: [[String:Any]] = [], unknownRows: [[String:Any]] = []
        for group in expected["groups"] as! [[String:Any]] {
            for var row in group["meetings"] as! [[String:Any]] {
                let unknown = row["origin"] as? String == "received" && creationOnly.contains(row["id"] as! String)
                let title = unknown ? "Date unknown" : group["title"] as! String
                if unknown { row["startMs"] = NSNull(); unknownRows.append(row); continue }
                if groups.last?["title"] as? String == title {
                    var rows = groups[groups.count-1]["meetings"] as! [[String:Any]]; rows.append(row)
                    groups[groups.count-1]["meetings"] = rows
                } else { groups.append(["title":title,"meetings":[row]]) }
            }
        }
        if !unknownRows.isEmpty { groups.append(["title":"Date unknown","meetings":unknownRows]) }
        expected["groups"] = groups; return expected
    }
    private static func nullable<T>(_ value: T?) -> Any { value.map { $0 as Any } ?? NSNull() }
    private static func row(_ meeting: LibraryMeeting) -> [String: Any] {
        let state = meeting.state
        return ["id": meeting.id.uuidString.lowercased(), "origin": state.origin.rawValue,
                "lifecycle": state.lifecycle.rawValue, "interruptedAtMs": nullable(state.interruptedAtMs),
                "transcript": state.transcript.rawValue, "etaMinutes": nullable(state.etaMinutes),
                "error": nullable(state.error.map { ["id": $0.id, "action": nullable($0.action)] as [String: Any] }),
                "badge": nullable(state.badge?.text), "title": nullable(meeting.title),
                "startMs": nullable(meeting.start.map { Int64(($0.timeIntervalSince1970 * 1000).rounded()) }),
                "durationMs": nullable(meeting.durationMs), "names": meeting.speakerNames,
                "quote": nullable(meeting.quote?.displayText), "canWriteDown": meeting.canWriteDown,
                "speakers": meeting.speakers.map { ["id": $0.id, "name": $0.displayName, "colourIndex": $0.colourIndex] as [String: Any] }]
    }
}
