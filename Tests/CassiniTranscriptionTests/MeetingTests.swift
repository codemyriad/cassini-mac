// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
import Foundation
import CryptoKit
import CassiniLibrary
import CassiniRecording
import CassiniWhistle
@testable import CassiniTranscription

final class TranscriptionMeetingTests: XCTestCase {
    func testSourceNamesAndPlainOpusIdentity() {
        XCTAssertEqual(TranscriptSpeaker.fromTrack(id: "original", kind: "system", received: true).id, "track-original")
        XCTAssertNil(TranscriptSpeaker.fromTrack(id: "original", kind: "system", received: true).name)
        XCTAssertEqual(TranscriptSpeaker.fromTrack(id: "microphone", kind: "microphone").name, "Me")
        XCTAssertEqual(TranscriptSpeaker.fromTrack(id: "system", kind: "system").name, "The others")
        XCTAssertEqual(TranscriptSpeaker.fromTrack(id: "42", kind: "remote").id, "track-42")
        XCTAssertNil(TranscriptSpeaker.fromTrack(id: "42", kind: "remote").name)
    }
    func testReceivedPlainOpusBecomesOneUnnamedSpeaker() throws {
        guard let assets = ProcessInfo.processInfo.environment["CASSINI_PIPELINE_ASSETS"] else { throw XCTSkip("Pinned offline assets supplied by pipeline CI") }
        let original = Bundle.module.url(forResource: "jfk-received", withExtension: "opus", subdirectory: "Fixtures")!
        let before = SHA256.hash(data: try Data(contentsOf: original))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let imported = try ReceivedAudioImport.copy(original, into: root)
        XCTAssertEqual(imported.state.origin,.received); XCTAssertTrue(imported.canWriteDown)
        XCTAssertFalse(imported.canQueueAutomatically)
        let vad = try VADAssets.forWorker(arguments: ["--assets",assets])
        let detector = try SpeechDetector(assets: vad)
        let engine = try WhistleEngine(assets: WhistleAssets.pinned(directory: URL(fileURLWithPath: assets)))
        try MeetingTranscriber.run(directory: imported.folder, engine: engine, detector: detector)
        let written = try XCTUnwrap(LibraryScanner(root: root).scan().meetings.first)
        XCTAssertEqual(written.state.transcript,.done); XCTAssertFalse(written.transcriptItems.isEmpty)
        XCTAssertEqual(written.speakers.count,1)
        XCTAssertEqual(written.speakers.first?.id,"track-original")
        XCTAssertEqual(written.speakers.first?.displayName,"Speaker 1")
        XCTAssertEqual(written.speakers.first?.provenance,.unnamed)
        XCTAssertNil(written.speakers.first?.name)
        XCTAssertEqual(SHA256.hash(data: try Data(contentsOf: original)),before)
    }
    func testPausePreservesPartialWordsAndExistingMetadata() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let session = try RecordingSession(parent:root,title:"Pause",source:"macos")
        try session.addTrack(id:"mic",label:"Mic",kind:"microphone",sampleRate:16000,channels:1)
        try session.append(id:"mic",pcm:Data(repeating:0,count:32000),offsetMs:0); try session.finish()
        let words: [String:Any] = ["language":"en","items":[["speaker":"me","startMs":0,"endMs":160,"text":"Partial words"]]]
        let bytes = try JSONSerialization.data(withJSONObject:words)
        let sidecar = session.directory.appendingPathComponent("transcript.json"); try bytes.write(to:sidecar)
        let writer = try MeetingMetadataWriter(directory:session.directory,id:session.manifest.id)
        try writer.transaction { meta in
            meta["title"] = "Keep the title"; meta["notes"] = [["atMs":12,"text":"Keep the note"]]
            meta["speakers"] = [["id":"me","name":"Renamed","provenance":"user","colourIndex":0]]
            meta["transcript"] = ["status":"running","reference":["kind":"sidecar","file":"transcript.json","format":"cassini.words.v1"]]
            meta["etaMinutes"] = 3
        }
        try MeetingTranscriber.pauseForResume(directory:session.directory,id:session.manifest.id)
        let meeting = try XCTUnwrap(LibraryScanner(root:root).scan().meetings.first)
        XCTAssertEqual(meeting.state.transcript,.queued); XCTAssertNil(meeting.state.error); XCTAssertNil(meeting.state.etaMinutes)
        XCTAssertEqual(meeting.transcriptItems.count,1); XCTAssertEqual(meeting.title,"Keep the title")
        XCTAssertEqual(meeting.notes.first?.text,"Keep the note"); XCTAssertEqual(meeting.speakers.first?.displayName,"Renamed")
        XCTAssertEqual(try Data(contentsOf:sidecar),bytes)
        try MeetingTranscriber.setStatus(directory:session.directory,id:session.manifest.id,status:"done")
        try MeetingTranscriber.pauseForResume(directory:session.directory,id:session.manifest.id)
        XCTAssertEqual(try LibraryScanner(root:root).scan().meetings.first?.state.transcript,.done)
    }
    func testResumeKeepsTheSavedTailUntilRecognitionCatchesUp() throws {
        guard let assets = ProcessInfo.processInfo.environment["CASSINI_PIPELINE_ASSETS"] else { throw XCTSkip("Pinned offline assets supplied by pipeline CI") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let session = try RecordingSession(parent:root,title:"Resume",source:"macos")
        try session.addTrack(id:"mic",label:"Mic",kind:"microphone",sampleRate:48000,channels:1)
        let url = Bundle.module.url(forResource:"pipeline-input-48k",withExtension:"wav",subdirectory:"Goldens")!
        let input = try Data(contentsOf:url).dropFirst(44)
        for at in stride(from:0,to:input.count,by:160000) {
            let first = input.startIndex + at, last = min(input.endIndex,first + 160000)
            try session.appendNative(id:"mic",pcm:Data(input[first..<last]),offsetMs:Double(at) / 96)
        }
        try session.finish()
        let sidecar = session.directory.appendingPathComponent("transcript.json")
        try JSONSerialization.data(withJSONObject:["language":"en","items":[["speaker":"me","startMs":30000,"endMs":30160,"text":"Retained old partial"]]]).write(to:sidecar)
        try MeetingMetadataWriter(directory:session.directory,id:session.manifest.id).transaction { meta in
            meta["transcript"] = ["status":"queued","reference":["kind":"sidecar","file":"transcript.json","format":"cassini.words.v1"]]
        }
        final class Outcome: @unchecked Sendable {
            let lock = NSLock(); private var result: Result<Void,Error>?
            func finish(_ result: Result<Void,Error>) { lock.lock(); self.result = result; lock.unlock() }
            func snapshot() -> Result<Void,Error>? { lock.lock(); defer { lock.unlock() }; return result }
        }
        let outcome = Outcome(), folder = session.directory
        Thread.detachNewThread {
            outcome.finish(Result {
                let vad = try VADAssets.forWorker(arguments:["--assets",assets])
                let detector = try SpeechDetector(assets:vad)
                let engine = try WhistleEngine(assets:WhistleAssets.pinned(directory:URL(fileURLWithPath:assets)))
                try MeetingTranscriber.run(directory:folder,engine:engine,detector:detector)
            })
        }
        let deadline = Date().addingTimeInterval(30); var sawMixedProgress = false
        while outcome.snapshot() == nil, Date() < deadline {
            if let data = try? Data(contentsOf:sidecar), let body = try? JSONSerialization.jsonObject(with:data) as? [String:Any],
               let words = body["items"] as? [[String:Any]], words.count > 1,
               words.contains(where: { ($0["text"] as? String) == "Retained old partial" }),
               words.contains(where: { ($0["startMs"] as? Int ?? Int.max) < 10000 }) { sawMixedProgress = true }
            Thread.sleep(forTimeInterval:0.01)
        }
        let result = try XCTUnwrap(outcome.snapshot()); try result.get()
        XCTAssertTrue(sawMixedProgress,"Saved later words must remain while the beginning is re-recognized")
        let meeting = try XCTUnwrap(LibraryScanner(root:root).scan().meetings.first)
        XCTAssertEqual(meeting.state.transcript,.done)
        XCTAssertFalse(meeting.transcriptItems.contains { $0.text == "Retained old partial" })
        XCTAssertEqual(meeting.transcriptItems.count,68)
    }
    func testRetryDiscardsFailedWordsWithoutChangingNotesOrSpeakers() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let session = try RecordingSession(parent:root,title:"Retry",source:"macos")
        try session.addTrack(id:"mic",label:"Mic",kind:"microphone",sampleRate:16000,channels:1)
        try session.append(id:"mic",pcm:Data(repeating:0,count:32000),offsetMs:0); try session.finish()
        try JSONSerialization.data(withJSONObject:["language":"en","items":[["speaker":"me","startMs":0,"endMs":160,"text":"Failed words"]]]).write(to:session.directory.appendingPathComponent("transcript.json"))
        try MeetingMetadataWriter(directory:session.directory,id:session.manifest.id).transaction {
            $0["notes"] = [["atMs":0,"text":"Keep"]]
            $0["speakers"] = [["id":"me","name":"Me","provenance":"source","colourIndex":0]]
            $0["transcript"] = ["status":"failed","reference":["kind":"sidecar","file":"transcript.json","format":"cassini.words.v1"]]
        }
        try MeetingTranscriber.setStatus(directory:session.directory,id:session.manifest.id,status:"queued")
        let queued = try XCTUnwrap(LibraryScanner(root:root).scan().meetings.first)
        XCTAssertEqual(queued.state.transcript,.queued); XCTAssertTrue(queued.transcriptItems.isEmpty)
        XCTAssertEqual(queued.notes.first?.text,"Keep")
        let metadata = try JSONSerialization.jsonObject(with:Data(contentsOf:session.directory.appendingPathComponent("meeting.json"))) as! [String:Any]
        XCTAssertEqual((metadata["speakers"] as? [[String:Any]])?.first?["name"] as? String,"Me")
    }
    func testProductionWriterPipelineOffsetsAndReadOnlyAudio() throws {
        guard let assets = ProcessInfo.processInfo.environment["CASSINI_PIPELINE_ASSETS"] else { throw XCTSkip("Pinned offline assets supplied by pipeline CI") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try RecordingSession(parent: root, title: "Offline speech", source: "macos")
        try session.addTrack(id: "mic", label: "Microphone", kind: "microphone", sampleRate: 16000, channels: 1)
        try session.addTrack(id: "other", label: "System", kind: "system", sampleRate: 16000, channels: 1)
        let source = Bundle.module.url(forResource: "segmentation-input", withExtension: "wav", subdirectory: "Goldens")!
        let bytes = try Data(contentsOf: source).dropFirst(44)
        // A single utterance is enough for real VAD + recognition + source metadata.
        let speech = Data(bytes.prefix(16000 * 4 * 2))
        try session.append(id: "mic", pcm: speech, offsetMs: 125)
        try session.append(id: "other", pcm: speech, offsetMs: 0)
        let stillGrowing = try XCTUnwrap(LibraryScanner(root: root).scan().meetings.first)
        XCTAssertEqual(stillGrowing.state.lifecycle,.saved) // no live adapter connected
        XCTAssertFalse(stillGrowing.canQueueAutomatically)
        try session.finish()
        let finished = try XCTUnwrap(LibraryScanner(root: root).scan().meetings.first)
        XCTAssertTrue(finished.canQueueAutomatically)
        let manifestURL = session.directory.appendingPathComponent("session.json")
        var manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as! [String:Any]
        var tracks = manifest["tracks"] as! [[String:Any]]; tracks[1]["startOffsetMs"] = NSNull(); manifest["tracks"] = tracks
        try JSONSerialization.data(withJSONObject: manifest).write(to: manifestURL)
        let writer = try MeetingMetadataWriter(directory: session.directory, id: session.manifest.id)
        try writer.transaction { $0["title"] = "Kept title"; $0["notes"] = [["atMs":0,"text":"Kept note"]] }
        let protected = [manifestURL] + session.manifest.tracks.map { session.directory.appendingPathComponent($0.file) }
        let before = try protected.map { SHA256.hash(data: try Data(contentsOf: $0)) }
        let vad = try VADAssets.forWorker(arguments: ["--assets",assets])
        let detector = try SpeechDetector(assets: vad)
        let engine = try WhistleEngine(assets: WhistleAssets.pinned(directory: URL(fileURLWithPath: assets)))
        let beforeMeeting = try XCTUnwrap(LibraryScanner(root: root).scan().meetings.first)
        XCTAssertEqual(beforeMeeting.state.lifecycle, .saved, String(describing: beforeMeeting))
        XCTAssertFalse(beforeMeeting.audioFiles.isEmpty, String(describing: beforeMeeting))
        try MeetingTranscriber.run(directory: session.directory, engine: engine, detector: detector)
        let meeting = try XCTUnwrap(LibraryScanner(root: root).scan().meetings.first)
        XCTAssertEqual(meeting.state.transcript, .done); XCTAssertEqual(meeting.title, "Kept title")
        XCTAssertEqual(meeting.notes.first?.text, "Kept note"); XCTAssertFalse(meeting.canPlaySession)
        XCTAssertEqual(Set(meeting.speakers.map(\.id)), ["me","others"])
        XCTAssertEqual(Set(meeting.speakers.compactMap(\.provenance)), [.source])
        let mic = meeting.transcriptItems.filter { $0.speaker == "me" }, other = meeting.transcriptItems.filter { $0.speaker == "others" }
        XCTAssertEqual(mic.count, other.count); XCTAssertFalse(mic.isEmpty)
        for (a,b) in zip(mic,other) { XCTAssertEqual(a.startMs - b.startMs,125); XCTAssertEqual(a.endMs - b.endMs,125); XCTAssertEqual(a.text,b.text) }
        XCTAssertEqual(try protected.map { SHA256.hash(data: try Data(contentsOf: $0)) }, before)
        let metadata = try JSONSerialization.jsonObject(with: Data(contentsOf: session.directory.appendingPathComponent("meeting.json"))) as! [String:Any]
        XCTAssertTrue(metadata["etaMinutes"] is NSNull)
    }
}
