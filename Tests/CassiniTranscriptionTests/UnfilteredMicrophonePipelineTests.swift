// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import CryptoKit
import XCTest
import CassiniLibrary
import CassiniWhistle
@testable import CassiniTranscription

final class UnfilteredMicrophonePipelineTests: XCTestCase {
    func testBrowserLocalAndRemoteSourcesKeepAllWordsThroughPipeline() throws {
        try assertSourceKindsKeepAllWords(microphone:"local",other:"remote",source:"chromium")
    }
    func testMicrophoneAndApplicationSourcesKeepAllWordsThroughPipeline() throws {
        try assertSourceKindsKeepAllWords(microphone:"microphone",other:"application",source:"macos")
    }
    private func assertSourceKindsKeepAllWords(microphone: String, other: String, source: String) throws {
        guard let assets = ProcessInfo.processInfo.environment["CASSINI_PIPELINE_ASSETS"] else { throw XCTSkip("Pinned offline assets supplied by pipeline CI") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CassiniEchoSourceKinds-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let key = "Recording-b1eed000-0000-4000-8000-000000000002"
        let fixture = URL(fileURLWithPath:#filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/Echo/Recordings/"+key)
        let folder = root.appendingPathComponent(key)
        try FileManager.default.copyItem(at:fixture,to:folder)
        let manifestURL = folder.appendingPathComponent("session.json")
        var manifest = try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:manifestURL)) as? [String:Any])
        var tracks = try XCTUnwrap(manifest["tracks"] as? [[String:Any]])
        tracks[0]["kind"] = microphone; tracks[1]["kind"] = other
        manifest["tracks"] = tracks; manifest["source"] = source
        try JSONSerialization.data(withJSONObject:manifest).write(to:manifestURL)
        let audio = try tracks.map { track -> (URL,Data) in
            let url = folder.appendingPathComponent(try XCTUnwrap(track["file"] as? String))
            return (url,try Data(contentsOf:url))
        }
        let engine = try WhistleEngine(assets:WhistleAssets.forWorker(arguments:["--assets",assets]))
        let detector = try SpeechDetector(assets:VADAssets.forWorker(arguments:["--assets",assets]))
        // Use the actual scanner, source selection, VAD, recognizer and persisted
        // transcript. Shared policy vectors alone cannot catch a missing kind.
        try MeetingTranscriber.run(directory:folder,engine:engine,detector:detector)
        let meeting = try XCTUnwrap(LibraryScanner(root:root).scan().meetings.first)
        XCTAssertEqual(meeting.state.transcript,.done)
        XCTAssertEqual(Set(meeting.audioTracks.compactMap(\.sourceKind)),Set([microphone,other]))
        let mine = meeting.transcriptItems.filter { $0.speaker == "me" }
        let theirs = meeting.transcriptItems.filter { $0.speaker != "me" }
        XCTAssertFalse(mine.isEmpty)
        XCTAssertTrue(mine.contains { $0.text.localizedCaseInsensitiveContains("budget") },"The microphone words remain")
        XCTAssertFalse(theirs.isEmpty)
        let body=try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:folder.appendingPathComponent("transcript.json"))) as? [String:Any])
        let words=try XCTUnwrap(body["items"] as? [[String:Any]])
        XCTAssertTrue(words.allSatisfy { $0["echo"] == nil },"D46 adds no post-recognition flags")
        XCTAssertEqual(MeetingPresentation.turns(meeting.transcriptItems).flatMap(\.items).count,words.count)
        for (url,before) in audio { XCTAssertEqual(try Data(contentsOf:url),before) }
    }
    func testThreeRealWhistleMeetingsKeepEveryRecognizedWord() throws {
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
            let data=try Data(contentsOf:folder.appendingPathComponent("transcript.json"))
            let body=try XCTUnwrap(JSONSerialization.jsonObject(with:data) as? [String:Any])
            let words=try XCTUnwrap(body["items"] as? [[String:Any]])
            XCTAssertTrue(words.allSatisfy { $0["echo"] == nil },name)
            XCTAssertEqual(MeetingPresentation.turns(meeting.transcriptItems).flatMap(\.items).count,words.count,name)
            XCTAssertFalse(words.isEmpty,name)
            if let report = ProcessInfo.processInfo.environment["CASSINI_PIPELINE_REPORT_DIR"] {
                let directory = URL(fileURLWithPath:report); try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
                try Data(contentsOf:folder.appendingPathComponent("transcript.json")).write(to:directory.appendingPathComponent("echo-"+name+".json"))
            }
        }
    }
}
