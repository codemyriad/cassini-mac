// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
import CassiniKit
@testable import CassiniLibrary

/// D47/D56: every meeting.json write keeps what it did not change verbatim, including
/// members this app does not know (speakers[].voiceSource, unknown note or top-level
/// members) and their exact number literals.
struct D56VerbatimMetadataTests {
    @Test func unknownMembersAndTheirLiteralsSurviveEveryWrite() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("D56-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID(), folder = root.appendingPathComponent("Recording-" + id.uuidString.lowercased())
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let voice = #"{"inputSHA256":"\#(String(repeating: "a", count: 64))","turnsSHA256":"\#(String(repeating: "b", count: 64))"}"#
        let future = #"{"ratio":0.1,"negative":-0,"large":1e300,"huge":123456789012345678901234567890,"nested":[1.50,{"k":true}]}"#
        let text = """
        {"version":1,"revision":4,"id":"\(id.uuidString.lowercased())","title":null,"titleSource":"meeting-window",\
        "notes":[{"atMs":1500,"text":"Decision","colour":"amber"}],\
        "speakers":[{"id":"spk-1","name":null,"provenance":"unnamed","colourIndex":0,"voiceSource":\(voice),"futureSpeaker":0.25}],\
        "transcript":{"status":"none","reference":null},"etaMinutes":null,"error":null,"quoteOverride":null,"received":null,\
        "futureMember":\(future)}
        """
        try Data(text.utf8).write(to: folder.appendingPathComponent("meeting.json"))
        let writer = try MeetingMetadataWriter(directory: folder, id: id)
        try writer.transaction { $0["title"] = "Renamed"; $0["titleSource"] = "user" }
        // As the transcriber does: add a label to a stored speaker entry.
        try writer.transaction { metadata in
            var speakers = metadata["speakers"] as? [[String: Any]] ?? []
            speakers[0]["label"] = "Speaker 1"; metadata["speakers"] = speakers
        }
        let stored = try JSONParser.parse(Data(contentsOf: folder.appendingPathComponent("meeting.json")))
        #expect(try stored["futureMember"]?.encoded() == Data(future.utf8), "unknown member and its literals verbatim")
        #expect(try stored["speakers"]?.array?.first?["voiceSource"]?.encoded() == Data(voice.utf8))
        #expect(stored["speakers"]?.array?.first?["futureSpeaker"] == .number("0.25"))
        #expect(stored["speakers"]?.array?.first?["label"]?.string == "Speaker 1")
        #expect(stored["notes"]?.array?.first?["colour"]?.string == "amber")
        #expect(stored["title"]?.string == "Renamed" && stored["revision"] == .number("6"))
        #expect(stored.object?.map(\.0).prefix(4) == ["version", "revision", "id", "title"], "member order kept")
    }
    @Test func onlyValuesTheEditChangedTakeTheNewText() {
        let original = try! JSONParser.parse(Data(#"{"a":0.1,"b":-0,"c":1,"d":[1.0,2]}"#.utf8))
        let edited = try! JSONParser.parse(Data(#"{"a":0.10000000000000001,"b":0,"c":2,"d":[1,3],"e":"new"}"#.utf8))
        let merged = MeetingMetadataWriter.preserving(original, edited: edited)
        #expect(try! merged.encoded() == Data(#"{"a":0.1,"b":-0,"c":2,"d":[1.0,3],"e":"new"}"#.utf8))
    }
}
