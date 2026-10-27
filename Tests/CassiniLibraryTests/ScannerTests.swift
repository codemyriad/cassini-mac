import Foundation
import CryptoKit
import Testing
import CassiniKit
@testable import CassiniLibrary

final class Fixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString.lowercased())
    let id = UUID(uuidString: "9037a57c-c501-44e6-8f1a-56f4c9317695")!
    var folder: URL { root.appendingPathComponent("Recording-" + id.uuidString.lowercased()) }
    let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    init() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: repository.appendingPathComponent("browser-protocol/conformance/native-session"), to: folder)
    }
    deinit { try? FileManager.default.removeItem(at: root) }
    func editCapture(_ edit: (inout [String: Any]) -> Void) throws {
        let file = folder.appendingPathComponent("session.json")
        var json = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
        edit(&json); try JSONSerialization.data(withJSONObject: json).write(to: file, options: .atomic)
    }
    func metadata(in directory: URL? = nil, received: [String: Any]? = nil, edit: (inout [String: Any]) -> Void = { _ in }) throws {
        var json: [String: Any] = ["version": 1, "revision": 0, "id": id.uuidString, "title": "Renamed", "titleSource": "user", "notes": [], "speakers": [], "transcript": ["status": "none", "reference": NSNull()], "etaMinutes": NSNull(), "error": NSNull(), "quoteOverride": NSNull(), "received": received.map { $0 as Any } ?? NSNull()]
        edit(&json); try JSONSerialization.data(withJSONObject: json).write(to: (directory ?? folder).appendingPathComponent("meeting.json"), options: .atomic)
    }
    func received(plain: Bool = false) throws -> URL {
        try FileManager.default.removeItem(at: folder)
        let received = root.appendingPathComponent("Received-" + id.uuidString.lowercased())
        try FileManager.default.createDirectory(at: received, withIntermediateDirectories: true)
        let source = repository.appendingPathComponent("Tests/CassiniKitTests/Conformance/opus/\(plain ? "002-plain-audio" : "001-minimal-v1").opus")
        try FileManager.default.copyItem(at: source, to: received.appendingPathComponent("original.opus"))
        return received
    }
}

@Suite struct LibraryScannerTests {
    @Test func absentLibraryIsEmptyAndScanNeverCreatesIt() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString.lowercased())
        #expect(try LibraryScanner(root: root).scan().meetings.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: root.path))
        #expect(LibraryScanner().root.path.hasSuffix("/Music/Cassini"))
    }
    @Test func captureMetadataAndWaveBytesRemainUntouched() throws {
        let f = try Fixture()
        try f.metadata { $0["notes"] = [["atMs": 400, "text": "A note"]] }
        let manifest = try Data(contentsOf: f.folder.appendingPathComponent("session.json"))
        let sidecar = try Data(contentsOf: f.folder.appendingPathComponent("meeting.json"))
        let waveFiles = ["track-microphone.wav", "track-system.wav"]
        let waves = try waveFiles.map { try Data(contentsOf: f.folder.appendingPathComponent($0)) }
        let result = try #require(LibraryScanner(root: f.root).scan().meetings.first)
        #expect(result.title == "Renamed")
        #expect(result.durationMs == 1125)
        #expect(result.state.lifecycle == .saved && result.state.interruptedAtMs == nil)
        #expect(result.audioFiles.count == 2)
        #expect(result.notes.first?.text == "A note")
        #expect(try Data(contentsOf: f.folder.appendingPathComponent("session.json")) == manifest)
        #expect(try Data(contentsOf: f.folder.appendingPathComponent("meeting.json")) == sidecar)
        #expect(try waveFiles.map { try Data(contentsOf: f.folder.appendingPathComponent($0)) } == waves)
    }
    @Test func abandonedAndLiveAndSavingAreIndependentFromMetadataAndMtime() throws {
        let f = try Fixture(); try f.editCapture { $0["state"] = "recording" }
        let inactive = try #require(LibraryScanner(root: f.root).scan().meetings.first)
        #expect(inactive.state.lifecycle == .saved && inactive.state.interruptedAtMs == 1125)
        let active = LibraryScanner(root: f.root, activity: CaptureActivitySnapshot([f.id: .recording]))
        let now = try #require(inactive.start).addingTimeInterval(768)
        #expect(try active.scan(now: now).meetings.first?.state.badge?.text == "Recording 12:48")
        let saving = LibraryScanner(root: f.root, activity: CaptureActivitySnapshot([f.id: .saving]))
        #expect(try saving.scan().meetings.first?.state.badge?.text == "Saving…")
        try f.editCapture { $0["problemKind"] = "gap" }
        let gap = try #require(active.scan(now: now).meetings.first)
        #expect(gap.state.interruptedAtMs == 1125)
        #expect(gap.state.badge?.kind == "recording")
    }
    @Test func unreadableCaptureKeepsItsRowAndUsesDisplayOnlyZeroOffsets() throws {
        let f = try Fixture()
        let original = Data("broken".utf8)
        try original.write(to: f.folder.appendingPathComponent("session.json"))
        let result = try #require(LibraryScanner(root: f.root).scan().meetings.first)
        #expect(result.durationMs == 1000)
        #expect(result.state.interruptedAtMs == 1000)
        #expect(result.state.badge?.text == "Interrupted at 00:00:01")
        #expect(result.issues.contains(.unknownStartOffset))
        #expect(result.start == nil && result.audioFiles.count == 2)
        #expect(try Data(contentsOf: f.folder.appendingPathComponent("session.json")) == original)
    }
    @Test func staleHeaderAndManifestCannotHideCompleteFrames() throws {
        let f = try Fixture()
        var wave = try Data(contentsOf: f.folder.appendingPathComponent("track-system.wav"))
        wave.replaceSubrange(40..<44, with: [0, 0, 0, 0])
        try wave.write(to: f.folder.appendingPathComponent("track-system.wav"))
        #expect(try LibraryScanner(root: f.root).scan().meetings.first?.durationMs == 1125)
    }
    @Test func oneMissingWaveDoesNotHideTheOtherSource() throws {
        let f = try Fixture(); try FileManager.default.removeItem(at: f.folder.appendingPathComponent("track-microphone.wav"))
        let result = try #require(LibraryScanner(root: f.root).scan().meetings.first)
        #expect(result.audioFiles.count == 1 && result.durationMs == 1125)
        #expect(result.issues.contains(.invalidAudio))
        #expect(result.state.interruptedAtMs == nil)
    }
    @Test func speakerOrderQuoteSelectionAndOverrideUseTranscriptNotCaptureSources() throws {
        let f = try Fixture()
        try f.metadata {
            $0["transcript"] = ["status": "done", "reference": ["kind": "sidecar", "file": "transcript.json", "format": "cassini.words.v1"]]
            $0["speakers"] = [["id": "b", "name": "Dario", "provenance": "recognised", "colourIndex": 1]]
        }
        let words: [String: Any] = ["language": "en", "items": [
            ["speaker": "b", "startMs": 11000, "endMs": 21000, "text": "Longest turn"],
            ["speaker": "a", "startMs": 0, "endMs": 2000, "text": "First speaker"],
            ["speaker": "c", "startMs": 610000, "endMs": 900000, "text": "Outside the quote window"]]]
        try JSONSerialization.data(withJSONObject: words).write(to: f.folder.appendingPathComponent("transcript.json"))
        let result = try #require(LibraryScanner(root: f.root).scan().meetings.first)
        #expect(result.speakerNames == ["Speaker 1", "Dario", "Speaker 3"])
        #expect(result.quote?.text == "Longest turn")
        #expect(result.quote?.displayText == "“Longest turn”")
        try f.metadata {
            $0["transcript"] = ["status": "done", "reference": ["kind": "sidecar", "file": "transcript.json", "format": "cassini.words.v1"]]
            $0["quoteOverride"] = ["atMs": 400, "text": "Last played"]
        }
        #expect(try LibraryScanner(root: f.root).scan().meetings.first?.quote?.text == "Last played")
    }
    @Test(arguments: [false, true]) func receivedTranscriptAndPlainAudioHaveDifferentActions(plain: Bool) throws {
        let f = try Fixture(); let received = try f.received(plain: plain)
        let data = try Data(contentsOf: received.appendingPathComponent("original.opus"))
        try f.metadata(in: received, received: ["originalName": "original.opus", "originalFolderName": "Downloads", "sha256": SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), "importedAtMs": 1793107080000]) { json in
            if !plain { json["transcript"] = ["status": "done", "reference": ["kind": "embedded", "file": "original.opus"]] }
        }
        let result = try #require(LibraryScanner(root: f.root).scan().meetings.first)
        #expect(result.state.origin == .received && result.state.badge?.kind == "received")
        #expect(result.state.canWriteDown == plain)
        #expect(result.state.transcript == (plain ? .none : .done))
        #expect(result.durationMs != nil)
        #expect(try Data(contentsOf: received.appendingPathComponent("original.opus")) == data)
    }
    @Test func damagedSidecarDoesNotClaimDoneOrDropAudio() throws {
        let f = try Fixture()
        try f.metadata {
            $0["transcript"] = ["status": "done", "reference": ["kind": "sidecar", "file": "transcript.json", "format": "cassini.words.v1"]]
            $0["quoteOverride"] = ["atMs": 0, "text": "Must not show"]
        }
        try Data("broken".utf8).write(to: f.folder.appendingPathComponent("transcript.json"))
        let result = try #require(LibraryScanner(root: f.root).scan().meetings.first)
        #expect(result.state.transcript == .damaged && result.state.error?.id == "transcript-damaged")
        #expect(result.state.badge == nil && result.audioFiles.count == 2 && result.quote == nil)
    }
    @Test func escapingFoldersAndSidecarPathsAreRejectedWithoutReadingThem() throws {
        let f = try Fixture()
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString.lowercased())
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        let link = f.root.appendingPathComponent("Recording-" + UUID().uuidString.lowercased())
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        try f.metadata { $0["transcript"] = ["status": "done", "reference": ["kind": "sidecar", "file": "../outside.json", "format": "cassini.words.v1"]] }
        let result = try LibraryScanner(root: f.root).scan()
        #expect(result.meetings.count == 1 && result.issues.contains(.unsafePath))
        #expect(try #require(result.meetings.first).issues.contains(.invalidMetadata))
    }
}
