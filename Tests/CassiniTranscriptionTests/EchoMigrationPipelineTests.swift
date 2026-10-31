// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import CryptoKit
import Darwin
import XCTest
import CassiniLibrary
@testable import CassiniTranscription

final class EchoMigrationPipelineTests: XCTestCase {
    private let fixtures = URL(fileURLWithPath:#filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/Echo")
    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CassiniOldEcho-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        addTeardownBlock { try? FileManager.default.removeItem(at:root) }; return root
    }
    private func meeting(_ name: String = "bleed", in root: URL) throws -> URL {
        let number = ["clean":1,"bleed":2,"room":3][name]!
        let folderName = "Recording-b1eed000-0000-4000-8000-00000000000\(number)"
        let folder = root.appendingPathComponent(folderName)
        try FileManager.default.copyItem(at:fixtures.appendingPathComponent("Recordings/"+folderName),to:folder)
        try FileManager.default.copyItem(at:fixtures.appendingPathComponent("PreD38/"+name+".json"),to:folder.appendingPathComponent("transcript.json"))
        let id = try XCTUnwrap(UUID(uuidString:String(folderName.dropFirst("Recording-".count))))
        try MeetingMetadataWriter(directory:folder,id:id).transaction {
            $0["transcript"] = ["status":"done","reference":["kind":"sidecar","file":"transcript.json","format":"cassini.words.v1"],"model":"whistle"]
            $0["notes"] = [["atMs":120,"text":"Keep this note"]]
            $0["extra-test-metadata"] = ["keep":true]
        }
        return folder
    }
    private func document(_ folder: URL) throws -> [String:Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:folder.appendingPathComponent("transcript.json"))) as? [String:Any])
    }
    func testEveryPreD38MeetingClassifiesWithoutModelsAndPreservesAllWordsAndProducerBytes() throws {
        let root = try root()
        let hashes = try XCTUnwrap((JSONSerialization.jsonObject(with:Data(contentsOf:fixtures.appendingPathComponent("PreD38/UPSTREAM.json"))) as? [String:Any])?["sha256"] as? [String:String])
        for (name,count) in [("clean",0),("bleed",49),("room",48)] {
            let raw = try Data(contentsOf:fixtures.appendingPathComponent("PreD38/"+name+".json"))
            XCTAssertEqual(SHA256.hash(data:raw).map { String(format:"%02x",$0) }.joined(),hashes[name+".json"])
            let folder = try meeting(name,in:root)
            let preserved = try ["meeting.json","session.json","track-microphone.wav","track-system.wav"].map { ($0,try Data(contentsOf:folder.appendingPathComponent($0))) }
            let before = try document(folder)
            XCTAssertEqual(try ExistingTranscriptEcho.run(directory:folder),.classified(count))
            let after = try document(folder)
            let words = try XCTUnwrap(after["items"] as? [[String:Any]])
            XCTAssertEqual(words.filter { ($0["echo"] as? Bool) == true }.count,count)
            var unflagged = after; unflagged["items"] = words.map { item in var item = item; item.removeValue(forKey:"echo"); return item }
            XCTAssertEqual(NSDictionary(dictionary:unflagged),NSDictionary(dictionary:before),"Every saved word, time, speaker and extra field stays unchanged")
            for (name,data) in preserved { XCTAssertEqual(try Data(contentsOf:folder.appendingPathComponent(name)),data) }
            let transcript = try Data(contentsOf:folder.appendingPathComponent("transcript.json"))
            let marker = try Data(contentsOf:folder.appendingPathComponent(ExistingTranscriptEcho.markerName))
            XCTAssertEqual(try ExistingTranscriptEcho.run(directory:folder),.alreadyComplete)
            XCTAssertEqual(try Data(contentsOf:folder.appendingPathComponent("transcript.json")),transcript)
            XCTAssertEqual(try Data(contentsOf:folder.appendingPathComponent(ExistingTranscriptEcho.markerName)),marker)
            if let output = ProcessInfo.processInfo.environment["CASSINI_PIPELINE_REPORT_DIR"] {
                let reports = URL(fileURLWithPath:output).appendingPathComponent("migration")
                try FileManager.default.createDirectory(at:reports,withIntermediateDirectories:true)
                try transcript.write(to:reports.appendingPathComponent("echo-"+name+".json"))
            }
        }
    }
    func testMissingAudioStaysUntouchedAndCanResumeWhenAudioReturns() throws {
        let folder = try meeting(in:root()), source = folder.appendingPathComponent("track-system.wav")
        let audio = try Data(contentsOf:source), before = try Data(contentsOf:folder.appendingPathComponent("transcript.json"))
        try FileManager.default.removeItem(at:source)
        XCTAssertEqual(try ExistingTranscriptEcho.run(directory:folder),.ineligible)
        XCTAssertEqual(try Data(contentsOf:folder.appendingPathComponent("transcript.json")),before)
        XCTAssertFalse(FileManager.default.fileExists(atPath:folder.appendingPathComponent(ExistingTranscriptEcho.markerName).path))
        try audio.write(to:source)
        XCTAssertEqual(try ExistingTranscriptEcho.run(directory:folder),.classified(49))
    }
    func testCancellationAndRecordingAdmissionBeforeCommitLeaveNoPartialFlagsOrMarker() throws {
        let folder = try meeting(in:root()), before = try Data(contentsOf:folder.appendingPathComponent("transcript.json"))
        var checks = 0
        XCTAssertThrowsError(try ExistingTranscriptEcho.run(directory:folder,checkpoint:{ checks += 1; if checks == 5 { throw CancellationError() } })) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertEqual(try Data(contentsOf:folder.appendingPathComponent("transcript.json")),before)
        XCTAssertThrowsError(try ExistingTranscriptEcho.run(directory:folder,commit:{ _ in throw CancellationError() })) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertEqual(try Data(contentsOf:folder.appendingPathComponent("transcript.json")),before)
        XCTAssertFalse(FileManager.default.fileExists(atPath:folder.appendingPathComponent(ExistingTranscriptEcho.markerName).path))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath:folder.path).contains { $0.hasPrefix(".echo-") && $0.hasSuffix(".tmp") })
        XCTAssertEqual(try ExistingTranscriptEcho.run(directory:folder),.classified(49))
    }
    func testConcurrentMetadataEditDoesNotGetOverwrittenOrMarkedComplete() throws {
        let folder = try meeting(in:root()), before = try Data(contentsOf:folder.appendingPathComponent("transcript.json"))
        let id = try XCTUnwrap(UUID(uuidString:String(folder.lastPathComponent.dropFirst("Recording-".count))))
        var checks = 0
        let result = try ExistingTranscriptEcho.run(directory:folder,checkpoint:{
            checks += 1
            if checks == 3 { try MeetingMetadataWriter(directory:folder,id:id).transaction { $0["title"] = "Edited during maintenance"; $0["titleSource"] = "user" } }
        })
        XCTAssertEqual(result,.changed)
        XCTAssertEqual(try Data(contentsOf:folder.appendingPathComponent("transcript.json")),before)
        XCTAssertFalse(FileManager.default.fileExists(atPath:folder.appendingPathComponent(ExistingTranscriptEcho.markerName).path))
        XCTAssertEqual(try ExistingTranscriptEcho.run(directory:folder),.classified(49))
    }
    func testOverlappingMicrophonesAreNeverGuessedFromTheSharedMeSpeaker() throws {
        let folder = try meeting(in:root()), manifest = folder.appendingPathComponent("session.json")
        var body = try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:manifest)) as? [String:Any])
        var tracks = try XCTUnwrap(body["tracks"] as? [[String:Any]])
        var second = tracks[0]; second["id"] = "second-mic"; second["file"] = "track-second-mic.wav"; second["kind"] = "local"
        try FileManager.default.copyItem(at:folder.appendingPathComponent("track-microphone.wav"),to:folder.appendingPathComponent("track-second-mic.wav"))
        tracks.append(second); body["tracks"] = tracks
        try JSONSerialization.data(withJSONObject:body).write(to:manifest)
        let before = try Data(contentsOf:folder.appendingPathComponent("transcript.json"))
        XCTAssertEqual(try ExistingTranscriptEcho.run(directory:folder),.classified(0))
        XCTAssertEqual(try Data(contentsOf:folder.appendingPathComponent("transcript.json")),before)
    }
    func testLocalRemoteAndMicrophoneApplicationKindsUseStoredPhysicalSources() throws {
        for (microphone,other) in [("local","remote"),("microphone","application")] {
            let folder = try meeting(in:root()), manifest = folder.appendingPathComponent("session.json")
            var body = try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:manifest)) as? [String:Any])
            var tracks = try XCTUnwrap(body["tracks"] as? [[String:Any]])
            tracks[0]["kind"] = microphone; tracks[1]["kind"] = other; body["tracks"] = tracks
            try JSONSerialization.data(withJSONObject:body).write(to:manifest)
            var transcript = try document(folder)
            transcript["items"] = try XCTUnwrap(transcript["items"] as? [[String:Any]]).map { item in
                var item = item; if item["speaker"] as? String == "others" { item["speaker"] = "track-system" }; return item
            }
            try JSONSerialization.data(withJSONObject:transcript).write(to:folder.appendingPathComponent("transcript.json"))
            XCTAssertEqual(try ExistingTranscriptEcho.run(directory:folder),.classified(49),microphone+"/"+other)
        }
    }
    func testUnsupportedAndSymlinkMarkersLeaveTheTranscriptUntouched() throws {
        for symlink in [false,true] {
            let folder = try meeting(in:root()), marker = folder.appendingPathComponent(ExistingTranscriptEcho.markerName)
            let before = try Data(contentsOf:folder.appendingPathComponent("transcript.json"))
            if symlink { try FileManager.default.createSymbolicLink(at:marker,withDestinationURL:folder.appendingPathComponent("transcript.json")) }
            else { try Data("{\"version\":2}".utf8).write(to:marker) }
            XCTAssertEqual(try ExistingTranscriptEcho.run(directory:folder),.ineligible)
            XCTAssertEqual(try Data(contentsOf:folder.appendingPathComponent("transcript.json")),before)
        }
    }
    func testCrashDraftIsRemovedAndAnotherTranscriberLeaseDefersThePass() throws {
        let folder = try meeting(in:root())
        let orphan = folder.appendingPathComponent(".echo-"+UUID().uuidString+".tmp")
        let unrelated = folder.appendingPathComponent(".echo-user-file.tmp")
        try Data("unfinished".utf8).write(to:orphan); try Data("keep".utf8).write(to:unrelated)
        let fd = open(folder.appendingPathComponent(".transcription.lock").path,O_RDWR | O_CREAT,0o600)
        XCTAssertGreaterThanOrEqual(fd,0); defer { close(fd) }
        XCTAssertEqual(flock(fd,LOCK_EX | LOCK_NB),0)
        XCTAssertEqual(try ExistingTranscriptEcho.run(directory:folder),.changed)
        XCTAssertEqual(flock(fd,LOCK_UN),0)
        XCTAssertEqual(try ExistingTranscriptEcho.run(directory:folder),.classified(49))
        XCTAssertFalse(FileManager.default.fileExists(atPath:orphan.path))
        XCTAssertEqual(try String(contentsOf:unrelated,encoding:.utf8),"keep")
    }
    func testNonoverlappingSpansWithOneMeSpeakerStillClassifyTheCorrectPhysicalSource() throws {
        let folder = try meeting(in:root()), manifest = folder.appendingPathComponent("session.json")
        var body = try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:manifest)) as? [String:Any])
        var tracks = try XCTUnwrap(body["tracks"] as? [[String:Any]])
        var second = tracks[0]; second["id"] = "later-mic"; second["file"] = "track-later-mic.wav"
        second["startOffsetMs"] = 50000; second["endOffsetMs"] = 93957
        try FileManager.default.copyItem(at:folder.appendingPathComponent("track-microphone.wav"),to:folder.appendingPathComponent("track-later-mic.wav"))
        tracks.append(second); body["tracks"] = tracks
        try JSONSerialization.data(withJSONObject:body).write(to:manifest)
        XCTAssertEqual(try ExistingTranscriptEcho.run(directory:folder),.classified(49))
    }
    func testMarkerCannotSkipAWordFileWhoseAtomicRenameWasLost() throws {
        let folder = try meeting(in:root()), transcript = folder.appendingPathComponent("transcript.json")
        let original = try Data(contentsOf:transcript)
        XCTAssertEqual(try ExistingTranscriptEcho.run(directory:folder),.classified(49))
        // Simulate a crash/recovery that retained the stamp but old word file.
        try original.write(to:transcript)
        XCTAssertEqual(try ExistingTranscriptEcho.run(directory:folder),.classified(49))
        XCTAssertEqual(try ExistingTranscriptEcho.run(directory:folder),.alreadyComplete)
    }
    func testExistingEchoFlagsNeverReclassify() throws {
        let folder = try meeting(in:root()), transcriptURL = folder.appendingPathComponent("transcript.json")
        var body = try document(folder); var items = try XCTUnwrap(body["items"] as? [[String:Any]])
        items[0]["echo"] = true; body["items"] = items
        let before = try JSONSerialization.data(withJSONObject:body); try before.write(to:transcriptURL)
        XCTAssertEqual(try ExistingTranscriptEcho.run(directory:folder),.classified(0))
        XCTAssertEqual(try Data(contentsOf:transcriptURL),before)
        XCTAssertEqual(try ExistingTranscriptEcho.run(directory:folder),.alreadyComplete)
    }
}
