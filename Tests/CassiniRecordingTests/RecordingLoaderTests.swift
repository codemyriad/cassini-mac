import Foundation
import Testing
@testable import CassiniRecording

@Suite struct RecordingLoaderTests {
    @Test(arguments: ["2026-10-27T08:59:42.047524+00:00", "2026-10-27T08:59:42Z"]) func readsBothPlatforms(date: String) throws {
        let json = """
        {"version":1,"id":"E5B7AE4F-127B-4279-9D22-8C8CAB73B66A","createdAt":"\(date)","title":"Meeting","source":"chromium","state":"completed","tracks":[]}
        """
        let manifest = try RecordingLoader.decode(Data(json.utf8))
        #expect(abs(manifest.createdAt.timeIntervalSince1970 - 1793091582) < 1)
    }
    @Test(arguments: ["macos", "gnome"]) func sharedNativeSessionFixture(source: String) throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let fixture = root.appendingPathComponent("browser-protocol/conformance/native-session")
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.copyItem(at: fixture, to: copy)
        defer { try? FileManager.default.removeItem(at: copy) }
        if source == "gnome" {
            try Data(contentsOf: copy.appendingPathComponent("session-gnome.json")).write(to: copy.appendingPathComponent("session.json"))
        }
        let manifest = try RecordingLoader.load(directory: copy)
        #expect(manifest.source == source)
        #expect(manifest.state == "completed")
        #expect(manifest.tracks.map(\.kind) == ["microphone", "system"])
        #expect(manifest.tracks.map(\.frames) == [8000, 8000])
        #expect(manifest.tracks.map(\.channels) == [1, 2])
        #expect(manifest.tracks.map(\.startOffsetMs) == [0, 125])
        #expect(manifest.tracks.map(\.endOffsetMs) == [1000, 1125])
        #expect(manifest.tracks.allSatisfy { $0.ended == true && $0.labelSource == "device" })
    }

    @Test(arguments: [Data(), Data("{broken".utf8)]) func recoversCorruptManifest(data: Data) throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: parent) }
        let session = try RecordingSession(parent: parent, title: "Lost title", source: "macos")
        try session.addTrack(id: "test", label: "Test", kind: "system", sampleRate: 48000, channels: 1)
        try session.append(id: "test", pcm: Data(repeating: 42, count: 9600), offsetMs: 250)
        try session.finish()
        try data.write(to: session.directory.appendingPathComponent("session.json"))
        let recovered = try RecordingLoader.load(directory: session.directory)
        #expect(recovered.state == "interrupted")
        #expect(recovered.problemKind == "recovery")
        #expect(recovered.tracks[0].frames == 4800)
        #expect(recovered.tracks[0].startOffsetMs == nil)
        #expect(try Data(contentsOf: session.directory.appendingPathComponent("session.json")) == data)
    }
    @Test func wavWinsOverStaleManifestAndSymlinkCannotEscape() throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: parent) }
        let session = try RecordingSession(parent: parent, title: "Test", source: "macos")
        try session.addTrack(id: "test", label: "Test", kind: "system", sampleRate: 48000, channels: 1)
        let stale = try Data(contentsOf: session.directory.appendingPathComponent("session.json"))
        try session.append(id: "test", pcm: Data(repeating: 42, count: 9600), offsetMs: 250)
        try session.finish()
        try stale.write(to: session.directory.appendingPathComponent("session.json"))
        #expect(try RecordingLoader.load(directory: session.directory).tracks[0].frames == 4800)
        let track = session.directory.appendingPathComponent(session.manifest.tracks[0].file)
        let outside = parent.appendingPathComponent("outside.wav")
        try FileManager.default.moveItem(at: track, to: outside)
        try FileManager.default.createSymbolicLink(at: track, withDestinationURL: outside)
        #expect(throws: (any Error).self) { try RecordingLoader.load(directory: session.directory) }
    }
}
