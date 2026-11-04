// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import XCTest
@testable import CassiniKit
@testable import CassiniLibrary
@testable import CassiniTranscription

final class UnfilteredTranscriptProjectionTests: XCTestCase {
    func testLegacyEchoFieldsCannotHideWordsInAnyProjection() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("CassiniD46-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer {try? FileManager.default.removeItem(at:root)}
        let source=URL(fileURLWithPath:#filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/Echo/Recordings/Recording-b1eed000-0000-4000-8000-000000000001")
        let folder=root.appendingPathComponent(source.lastPathComponent)
        try FileManager.default.copyItem(at:source,to:folder)
        let raw:[[String:Any]]=[
            ["speaker":"others","startMs":0,"endMs":100,"text":"Hello"],
            ["speaker":"me","startMs":300,"endMs":400,"text":"legacy-repeat","echo":true],
            ["speaker":"others","startMs":500,"endMs":600,"text":"world"],
            ["speaker":"me","startMs":1000,"endMs":1100,"text":"Yes"]]
        let body=try JSONSerialization.data(withJSONObject:["language":"en","items":raw])
        let file=folder.appendingPathComponent("transcript.json");try body.write(to:file)
        let meeting=try XCTUnwrap(LibraryScanner(root:root).scan().meetings.first)
        let texts=["Hello","legacy-repeat","world","Yes"]
        XCTAssertEqual(meeting.transcriptItems.map(\.text),texts)
        XCTAssertEqual(MeetingPresentation.turns(meeting.transcriptItems).flatMap(\.items).map(\.text),texts)
        XCTAssertEqual(meeting.transcriptTurns.map(\.text),texts)
        XCTAssertEqual(MeetingPresentation.shares(meeting),["others":50,"me":50])
        XCTAssertEqual(meeting.quote?.text,"Hello")
        XCTAssertTrue(MeetingMarkdown.render(meeting,timeZone:TimeZone(secondsFromGMT:0)!).contains("legacy-repeat"))
        let portable=try ManifestParser.words(JSONParser.parse(body))
        XCTAssertEqual(Timeline(portable.items).words.map(\.text),texts)
        let encoded=try XCTUnwrap(JSONSerialization.jsonObject(with:JSONEncoder().encode(meeting.transcriptItems)) as? [[String:Any]])
        XCTAssertTrue(encoded.allSatisfy { $0["echo"] == nil })
        XCTAssertEqual(try Data(contentsOf:file),body,"Reading existing meetings never rewrites stored words")
    }
    func testSourceKindsRemainAvailableForTheFuturePCMStage() {
        XCTAssertEqual(TranscriptionSourceKinds.microphones,["microphone","local"])
        XCTAssertEqual(TranscriptionSourceKinds.references,["system","application","remote","media","tab"])
        XCTAssertTrue(TranscriptionSourceKinds.microphones.isDisjoint(with:TranscriptionSourceKinds.references))
    }
}
