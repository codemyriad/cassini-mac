// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
import CassiniRecording
@testable import CassiniLibrary

struct RecordingLibraryTests {
    @Test func preparationIsHiddenAndIncrementalPromotionUsesTheRealProducerPhase() throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:parent) }
        let session = try RecordingSession(parent:parent,title:"Pending",source:"macos")
        let phases = PreparingActivity(id:session.manifest.id)
        let scanner = LibraryScanner(root:parent,activity:phases)
        #expect(try scanner.scan().meetings.isEmpty)
        try session.addTrack(id:"mic",label:"Me",kind:"microphone",sampleRate:8000,channels:1)
        try session.appendNative(id:"mic",pcm:Data(repeating:0,count:1600),offsetMs:0)
        phases.set(.recording)
        #expect(try scanner.scan(affected:session.directory).meetings.first?.state.lifecycle == .recording)
        phases.set(.preparing)
        #expect(try scanner.scan(affected:session.directory).meetings.isEmpty,"Preparation must evict any cached row")
        phases.set(.saving)
        #expect(try scanner.scan(affected:session.directory).meetings.first?.state.lifecycle == .saving)
        try session.finish()
    }
    @Test func nativeCaptureIsVisibleThroughoutItsLifetimeAndMetadataIsPrivate() throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: parent) }
        let session = try RecordingSession(parent: parent, title: "Native fixture", source: "macos")
        #expect(session.directory.lastPathComponent == "Recording-" + session.manifest.id.uuidString.lowercased())
        let metadata = try MeetingMetadataWriter(directory: session.directory, id: session.manifest.id)
        try metadata.createIfNeeded()
        try session.addTrack(id: "microphone", label: "Microphone", kind: "microphone", sampleRate: 48000, channels: 1)
        try session.appendNative(id: "microphone", pcm: Data(repeating: 0, count: 96000), offsetMs: 0)
        let live = try #require(LibraryScanner(root: parent, activity: CaptureActivitySnapshot([session.manifest.id: .recording])).scan().meetings.first)
        #expect(live.state.lifecycle == .recording && live.captureSource == "macos")
        #expect(live.state.interruptedAtMs == nil)
        let saving = try #require(LibraryScanner(root: parent, activity: CaptureActivitySnapshot([session.manifest.id: .saving])).scan().meetings.first)
        #expect(saving.state.lifecycle == .saving && saving.state.badge?.text == "Saving…")
        try session.finish()
        let saved = try #require(LibraryScanner(root: parent).scan().meetings.first)
        #expect(saved.state.lifecycle == .saved && saved.canPlaySession && saved.durationMs == 1000)
        #expect(saved.state.interruptedAtMs == nil && saved.state.transcript == .none)
        #expect((try FileManager.default.attributesOfItem(atPath: session.directory.path)[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        #expect((try FileManager.default.attributesOfItem(atPath: session.directory.appendingPathComponent("meeting.json").path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }
    @Test func appMetadataPreservesFieldsRejectsUnsafeAndDoesNotTouchCapture() throws {
        let f = try Fixture()
        let capture = try Data(contentsOf: f.folder.appendingPathComponent("session.json"))
        let writer = try MeetingMetadataWriter(directory: f.folder, id: f.id)
        try writer.createIfNeeded()
        try writer.createIfNeeded()
        try writer.transaction { $0["title"] = "A new title"; $0["titleSource"] = "user" }
        try writer.transaction { $0["notes"] = [["atMs": 1, "text": "Keep this note"]] }
        let metadata = try AppMetadata.parse(Data(contentsOf: f.folder.appendingPathComponent("meeting.json")))
        #expect(metadata.title == "A new title" && metadata.notes.count == 1 && metadata.revision == 2)
        #expect(try Data(contentsOf: f.folder.appendingPathComponent("session.json")) == capture)
        try FileManager.default.removeItem(at: f.folder.appendingPathComponent("meeting.json"))
        try FileManager.default.createSymbolicLink(at: f.folder.appendingPathComponent("meeting.json"), withDestinationURL: f.folder.appendingPathComponent("session.json"))
        #expect(throws: (any Error).self) { try writer.createIfNeeded() }
        #expect(try Data(contentsOf: f.folder.appendingPathComponent("session.json")) == capture)
    }
}
private final class PreparingActivity: CaptureActivityProviding, @unchecked Sendable {
    private let lock = NSLock()
    private let id: UUID
    private var phase: CaptureActivity = .preparing
    init(id: UUID) { self.id = id }
    func set(_ phase: CaptureActivity) { lock.withLock { self.phase = phase } }
    func snapshot() -> [UUID:CaptureActivity] { lock.withLock { [id:phase] } }
}
