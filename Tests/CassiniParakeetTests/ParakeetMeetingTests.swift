// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
import Foundation
import CryptoKit
import CassiniLibrary
import CassiniTranscription
import CassiniWhistle
import CassiniParakeet

final class ParakeetMeetingTests: XCTestCase {
    func testResumeKeepsOnlyWordsFromTheSameKnownModel() throws {
        guard let assets = ProcessInfo.processInfo.environment["CASSINI_PIPELINE_ASSETS"] else { throw XCTSkip("D11 Silero assets supplied by speech CI") }
        let fixture = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("CassiniTranscriptionTests/Fixtures/jfk-received.opus")
        for previousModel in [nil,"whistle",ParakeetPin.transcriptModel] as [String?] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at:root,withIntermediateDirectories:false)
            defer { try? FileManager.default.removeItem(at:root) }
            let meeting = try LibraryImport.copy(fixture,into:root)
            let audio = try Data(contentsOf:meeting.audioFiles[0])
            let writer = try MeetingMetadataWriter(directory:meeting.folder,id:meeting.id)
            let original: [String:Any] = ["language":"fr","items":[["speaker":"track-original","startMs":5000,"endMs":5100,"text":"existing"]]]
            try JSONSerialization.data(withJSONObject:original).write(to:meeting.folder.appendingPathComponent("transcript.json"))
            try writer.transaction {
                var transcript: [String:Any] = ["status":"queued","reference":["kind":"sidecar","file":"transcript.json","format":"cassini.words.v1"]]
                if let previousModel { transcript["model"] = previousModel }
                $0["transcript"] = transcript
                $0["notes"] = [["atMs":100,"text":"Keep this note"]]
                $0["speakers"] = [["id":"track-original","name":"A user label","provenance":"user","colourIndex":0]]
            }
            let before = try XCTUnwrap(LibraryScanner(root:root).scan().meetings.first)
            XCTAssertEqual(before.transcriptModel,previousModel)
            let detector = try SpeechDetector(assets:VADAssets.forWorker(arguments:["--assets",assets]))
            var observedInitial = false
            try MeetingTranscriber.run(directory:meeting.folder,detector:detector,model:ParakeetPin.transcriptModel,initialETA:0.3,initialLanguage:"und") { _ in
                if !observedInitial {
                    observedInitial = true
                    let current = try XCTUnwrap(LibraryScanner(root:root).scan().meetings.first)
                    XCTAssertEqual(current.transcriptModel,ParakeetPin.transcriptModel)
                    XCTAssertEqual(current.transcriptItems.contains { $0.text == "existing" },previousModel == ParakeetPin.transcriptModel)
                    XCTAssertEqual(current.transcriptLanguage,"und")
                }
                return .init(text:"New words",language:"und",words:[.init(word:"New",start:0,end:0.02,probability:1)])
            }
            XCTAssertTrue(observedInitial)
            let result = try XCTUnwrap(LibraryScanner(root:root).scan().meetings.first)
            XCTAssertEqual(result.state.transcript,.done)
            XCTAssertEqual(result.transcriptModel,ParakeetPin.transcriptModel)
            XCTAssertFalse(result.transcriptItems.contains { $0.text == "existing" })
            XCTAssertEqual(result.notes.first?.text,"Keep this note")
            XCTAssertEqual(result.speakers.first?.name,"A user label")
            XCTAssertEqual(try Data(contentsOf:result.audioFiles[0]),audio)
        }
    }
}
