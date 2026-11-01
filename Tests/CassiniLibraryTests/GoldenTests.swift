// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import CryptoKit
import Testing
@testable import CassiniLibrary

private struct FormatInput: Decodable {
    var ms: Int64?; var atMs: Int64?; var durationMs: Int64?; var received: Bool?; var positionMs: Int64?
    var names: [String]?; var minutes: Int64?; var places: Int64?; var meetings: Int64?; var bytes: Int64?; var approx: Bool?
}
private struct FormatCase: Sendable {
    var group: String; var id: String; var data: Data; var expected: String
}
private enum Golden {
    static func data(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Golden"))
        return try Data(contentsOf: url)
    }
    static let formats: [FormatCase] = {
        let root = try! JSONSerialization.jsonObject(with: data("format-vectors")) as! [String: Any]
        return root.keys.sorted().flatMap { key -> [FormatCase] in
            guard let cases = root[key] as? [[String: Any]] else { return [] }
            return cases.enumerated().map { index, value in .init(group: key, id: "\(key)-\(index)", data: try! JSONSerialization.data(withJSONObject: value), expected: value["out"] as! String) }
        }
    }()
    static let states: [Data] = {
        let root = try! JSONSerialization.jsonObject(with: data("states-vectors")) as! [String: Any]
        return (root["vectors"] as! [[String: Any]]).map { try! JSONSerialization.data(withJSONObject: $0) }
    }()
}

@Suite struct LibraryGoldenTests {
    @Test func searchOmitsUnknownDurationWithoutLosingTheHitPosition() {
        let date = Date(timeIntervalSince1970:0)
        let format = LibraryFormat(timeZone:TimeZone(secondsFromGMT:0)!,now:date,locale:Locale(identifier:"en_GB"),language:.en)
        #expect(format.searchContext(date,durationMs:nil,positionMs:300000) == "Today, 00:00 · at 00:05:00")
        #expect(format.searchContext(date,durationMs:0,positionMs:300000) == "Today, 00:00 · under 1 min · at 00:05:00")
    }
    @Test func goldenBytesAndCounts() throws {
        let hashes = ["format-vectors": "8d9449e30b28b117c85f5396de6b0123b1f79cc9b53f6504157b1a0dfffcc791",
                      "states-vectors": "33f4e5596d0d84912ea75388df2825e4008eae824b1c672f0c47c1482df89415",
                      "meeting.schema": "fa316da3862c7da2d9448dcadb44f7f8176f688ca294438ff630a4d0194026c3"]
        for (name, expected) in hashes {
            #expect(SHA256.hash(data: try Golden.data(name)).map { String(format: "%02x", $0) }.joined() == expected)
        }
        #expect(MetadataSchema.bytes == (try Golden.data("meeting.schema")))
        let rules = try #require(Bundle.module.url(forResource: "LIBRARY-RULES", withExtension: "md", subdirectory: "Golden"))
        #expect(SHA256.hash(data: try Data(contentsOf: rules)).map { String(format: "%02x", $0) }.joined() == "95a0e5068a08efa521f6eed73799b715ab50b2cf6aee374570b5337a6a3bdd2a")
        #expect(Golden.formats.count == 76)
        #expect(Golden.states.count == 17)
    }
    @Test(arguments: Golden.formats) private func formatVector(vector: FormatCase) throws {
        let value = try JSONDecoder().decode(FormatInput.self, from: vector.data)
        let header = try JSONSerialization.jsonObject(with: Golden.data("format-vectors")) as! [String: Any]
        let format = LibraryFormat(timeZone: try #require(TimeZone(identifier: header["tz"] as! String)), now: Date(timeIntervalSince1970: (header["nowMs"] as! NSNumber).doubleValue / 1000),locale:Locale(identifier:"en_GB"),language:.en)
        let at = Date(timeIntervalSince1970: Double(value.atMs ?? 0) / 1000)
        let actual: String
        switch vector.group {
        case "position": actual = LibraryFormat.position(try #require(value.ms),locale:Locale(identifier:"en_GB"),language:.en)
        case "liveBadge": actual = LibraryFormat.liveBadge(try #require(value.ms),locale:Locale(identifier:"en_GB"),language:.en)
        case "liveBig": actual = LibraryFormat.liveBig(try #require(value.ms),locale:Locale(identifier:"en_GB"),language:.en)
        case "meetingDuration": actual = LibraryFormat.meetingDuration(try #require(value.ms),locale:Locale(identifier:"en_GB"),language:.en)
        case "talkTime": actual = LibraryFormat.talkTime(try #require(value.ms),locale:Locale(identifier:"en_GB"),language:.en)
        case "confirmedSpeech": actual = LibraryFormat.confirmedSpeech(try #require(value.ms),locale:Locale(identifier:"en_GB"),language:.en)
        case "dayGroup": actual = format.dayGroup(at)
        case "rowTime": actual = format.rowTime(at)
        case "previewSubtitle": actual = format.previewSubtitle(at, durationMs: try #require(value.durationMs), received: value.received ?? false)
        case "searchDate": actual = format.searchDate(at)
        case "searchContext": actual = format.searchContext(at, durationMs: try #require(value.durationMs), positionMs: try #require(value.positionMs))
        case "rowMeta": actual = LibraryFormat.rowMeta(durationMs: try #require(value.durationMs), names: try #require(value.names),locale:Locale(identifier:"en_GB"),language:.en)
        case "eta": actual = LibraryFormat.eta(try #require(value.minutes),locale:Locale(identifier:"en_GB"),language:.en)
        case "searchCount": actual = LibraryFormat.searchCount(places: try #require(value.places), meetings: try #require(value.meetings),locale:Locale(identifier:"en_GB"),language:.en)
        case "size": actual = LibraryFormat.size(bytes: try #require(value.bytes), approximate: value.approx ?? false,locale:Locale(identifier:"en_GB"),language:.en)
        default: throw TestError.unknownGroup
        }
        #expect(actual == vector.expected, "\(vector.id): \(actual) != \(vector.expected)")
    }
    @Test(arguments: Golden.states) func stateVector(data: Data) throws {
        struct Vector: Decodable { var id: String; var fields: MeetingState; var badge: MeetingBadge?; var canWriteDown: Bool? }
        let vector = try JSONDecoder().decode(Vector.self, from: data)
        #expect(vector.fields.badge == vector.badge, "\(vector.id)")
        if let expected = vector.canWriteDown { #expect(vector.fields.canWriteDown == expected, "\(vector.id)") }
    }
    @Test func timeZoneUsesCalendarDaysAcrossDSTAndIgnoresTheProcessLocale() throws {
        let zone = try #require(TimeZone(identifier: "America/New_York"))
        let now = try #require(ISO8601DateFormatter().date(from: "2026-11-02T05:30:00Z"))
        let before = try #require(ISO8601DateFormatter().date(from: "2026-11-01T04:30:00Z"))
        let format = LibraryFormat(timeZone: zone, now: now,locale:Locale(identifier:"en_GB"),language:.en)
        #expect(format.dayGroup(before) == "Yesterday")
        #expect(format.rowTime(before) == "00:30")
        #expect(LibraryFormat.position(Int64.max) == "2562047788015:12:55")
    }
    enum TestError: Error { case unknownGroup }
}
