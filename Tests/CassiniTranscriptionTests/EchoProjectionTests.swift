// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import XCTest
@testable import CassiniKit
@testable import CassiniLibrary
@testable import CassiniTranscription

final class EchoProjectionTests: XCTestCase {
    func testSavedEchoIsAdditiveAndEveryTextProjectionSkipsIt() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CassiniEchoProjection-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let source = URL(fileURLWithPath:#filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/Echo/Recordings/Recording-b1eed000-0000-4000-8000-000000000001")
        let folder = root.appendingPathComponent(source.lastPathComponent)
        try FileManager.default.copyItem(at:source,to:folder)
        let words: [LibraryTranscriptItem] = [
            .init(speaker:"others",startMs:0,endMs:100,text:"Hello"),
            .init(speaker:"me",startMs:300,endMs:400,text:"echo-only",echo:true),
            .init(speaker:"others",startMs:500,endMs:600,text:"world"),
            .init(speaker:"me",startMs:1000,endMs:1100,text:"Yes")
        ]
        let data = try JSONEncoder().encode(words)
        let raw = try XCTUnwrap(JSONSerialization.jsonObject(with:data) as? [[String:Any]])
        XCTAssertNil(raw[0]["echo"]); XCTAssertEqual(raw[1]["echo"] as? Bool,true)
        let body = try JSONSerialization.data(withJSONObject:["language":"en","items":raw])
        try body.write(to:folder.appendingPathComponent("transcript.json"))
        let meeting = try XCTUnwrap(LibraryScanner(root:root).scan().meetings.first)
        XCTAssertEqual(meeting.transcriptItems,words)
        XCTAssertEqual(MeetingPresentation.turns(words).map { $0.items.map(\.text).joined(separator:" ") },["Hello world","Yes"])
        XCTAssertEqual(meeting.transcriptTurns.map(\.text),["Hello world","Yes"])
        XCTAssertEqual(MeetingPresentation.shares(meeting),["others":67,"me":33])
        XCTAssertEqual(meeting.quote?.text,"Hello world")
        XCTAssertFalse(MeetingMarkdown.render(meeting,timeZone:TimeZone(secondsFromGMT:0)!).contains("echo-only"))
        let portable = try ManifestParser.words(JSONParser.parse(body))
        XCTAssertEqual(portable.items.count,4); XCTAssertTrue(portable.items[1].echo)
        XCTAssertEqual(Timeline(portable.items).words.map(\.text),["Hello","world","Yes"])
        struct OldWord: Decodable { let speaker: String; let startMs: Int64; let endMs: Int64; let text: String }
        XCTAssertEqual(try JSONDecoder().decode([OldWord].self,from:data).count,4,"Old v1 readers ignore the additive flag")
    }
    func testResumeKeepsUnprocessedFlagsAndFreshWordsRecomputeThem() {
        let first = LibraryTranscriptItem(speaker:"me",startMs:100,endMs:200,text:"first",echo:true)
        let tail = LibraryTranscriptItem(speaker:"me",startMs:1000,endMs:1100,text:"tail",echo:true)
        var progress = TranscriptProgress(previous:[first,tail],speakers:["me","me"])
        progress.advance(track:0,to:500); progress.advance(track:1,to:500)
        let fresh = TranscriptProgress.Item(word:.init(speaker:"me",startMs:100,endMs:200,text:"first"),track:0,ordinal:0)
        XCTAssertEqual(progress.published([fresh]).map(\.echo),[false,true])
        XCTAssertEqual(progress.published([fresh],complete:true).map(\.echo),[false])
    }
}
