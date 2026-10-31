// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import CryptoKit
import XCTest
import CassiniLibrary
import CassiniWhistle
@testable import CassiniTranscription

final class EchoPipelineTests: XCTestCase {
    func testThreeRealWhistleBleedMeetingsKeepRawWordsAndProduceFilteredTurns() throws {
        guard let assets = ProcessInfo.processInfo.environment["CASSINI_PIPELINE_ASSETS"] else { throw XCTSkip("Pinned offline assets supplied by pipeline CI") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CassiniEchoPipeline-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let fixtures = URL(fileURLWithPath:#filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/Echo/Recordings")
        let pin = try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:fixtures.deletingLastPathComponent().appendingPathComponent("UPSTREAM.json"))) as? [String:Any])
        let hashes = try XCTUnwrap(pin["recordingsSHA256"] as? [String:String])
        XCTAssertEqual(hashes.count,9)
        for (path,hash) in hashes {
            XCTAssertEqual(SHA256.hash(data:try Data(contentsOf:fixtures.appendingPathComponent(path))).map { String(format:"%02x",$0) }.joined(),hash,path)
        }
        let engine = try WhistleEngine(assets:WhistleAssets.forWorker(arguments:["--assets",assets]))
        let detector = try SpeechDetector(assets:VADAssets.forWorker(arguments:["--assets",assets]))
        for (index,name) in ["clean","bleed","room"].enumerated() {
            let key = "Recording-b1eed000-0000-4000-8000-00000000000\(index+1)"
            let folder = root.appendingPathComponent(key)
            try FileManager.default.copyItem(at:fixtures.appendingPathComponent(key),to:folder)
            let mic = folder.appendingPathComponent("track-microphone.wav"), system = folder.appendingPathComponent("track-system.wav")
            let micBefore = try Data(contentsOf:mic), systemBefore = try Data(contentsOf:system)
            try MeetingTranscriber.run(directory:folder,engine:engine,detector:detector)
            let id = try XCTUnwrap(UUID(uuidString:String(key.dropFirst("Recording-".count))))
            let meeting = try XCTUnwrap(LibraryScanner(root:root).scan().meetings.first { $0.id == id })
            XCTAssertEqual(meeting.state.transcript,.done,name)
            XCTAssertEqual(try Data(contentsOf:mic),micBefore); XCTAssertEqual(try Data(contentsOf:system),systemBefore)
            XCTAssertLessThanOrEqual(MeetingPresentation.turns(meeting.transcriptItems).count,10,name)
            if index == 0 { XCTAssertTrue(meeting.transcriptItems.allSatisfy { !$0.echo },"Clean control output stays unchanged") }
            else { XCTAssertTrue(meeting.transcriptItems.contains { $0.echo },name) }
            if let report = ProcessInfo.processInfo.environment["CASSINI_PIPELINE_REPORT_DIR"] {
                let directory = URL(fileURLWithPath:report); try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
                try Data(contentsOf:folder.appendingPathComponent("transcript.json")).write(to:directory.appendingPathComponent("echo-"+name+".json"))
            }
        }
    }
}
