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
    @Test func goldenBytesAndCounts() throws {
        let hashes = ["format-vectors": "915a8cabd8af07c847ac55e479993b4af4bb4223e26ec447ce5e479543883773",
                      "states-vectors": "1f5cc52920abb8148942d0484e9c67cc734f613d7e90c07968ecf3622cb19702"]
        for (name, expected) in hashes {
            #expect(SHA256.hash(data: try Golden.data(name)).map { String(format: "%02x", $0) }.joined() == expected)
        }
        #expect(Golden.formats.count == 64)
        #expect(Golden.states.count == 15)
    }
    @Test(arguments: Golden.formats) private func formatVector(vector: FormatCase) throws {
        let value = try JSONDecoder().decode(FormatInput.self, from: vector.data)
        let format = LibraryFormat(timeZone: try #require(TimeZone(identifier: "Europe/Rome")), now: Date(timeIntervalSince1970: 1793107080))
        let at = Date(timeIntervalSince1970: Double(value.atMs ?? 0) / 1000)
        let actual: String
        switch vector.group {
        case "position": actual = LibraryFormat.position(try #require(value.ms))
        case "liveBadge": actual = LibraryFormat.liveBadge(try #require(value.ms))
        case "liveBig": actual = LibraryFormat.liveBig(try #require(value.ms))
        case "meetingDuration": actual = LibraryFormat.meetingDuration(try #require(value.ms))
        case "talkTime": actual = LibraryFormat.talkTime(try #require(value.ms))
        case "confirmedSpeech": actual = LibraryFormat.confirmedSpeech(try #require(value.ms))
        case "dayGroup": actual = format.dayGroup(at)
        case "rowTime": actual = format.rowTime(at)
        case "previewSubtitle": actual = format.previewSubtitle(at, durationMs: try #require(value.durationMs), received: value.received ?? false)
        case "searchDate": actual = format.searchDate(at)
        case "searchContext": actual = format.searchContext(at, durationMs: try #require(value.durationMs), positionMs: try #require(value.positionMs))
        case "rowMeta": actual = LibraryFormat.rowMeta(durationMs: try #require(value.durationMs), names: try #require(value.names))
        case "eta": actual = LibraryFormat.eta(try #require(value.minutes))
        case "searchCount": actual = LibraryFormat.searchCount(places: try #require(value.places), meetings: try #require(value.meetings))
        case "size": actual = LibraryFormat.size(bytes: try #require(value.bytes), approximate: value.approx ?? false)
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
        let format = LibraryFormat(timeZone: zone, now: now)
        #expect(format.dayGroup(before) == "Yesterday")
        #expect(format.rowTime(before) == "00:30")
        #expect(LibraryFormat.position(Int64.max) == "2562047788015:12:55")
    }
    enum TestError: Error { case unknownGroup }
}
