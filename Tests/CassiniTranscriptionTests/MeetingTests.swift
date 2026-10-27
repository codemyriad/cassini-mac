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
        try session.finish()
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
