// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
import CassiniLibrary
import CassiniRecording
@testable import CassiniSearch

/// D112 (L-86) / D-1169: Search omits background speakers from speaker filter names,
/// indexed turns, and context, and invalidates its cache when background flags toggle.
struct BackgroundVoiceSearchTests {
    private func makeMeeting() throws -> (URL, LibraryMeeting) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BgSearch-" + UUID().uuidString)
        let session = try RecordingSession(parent: root, title: "Cafe sync", source: "macos")
        try session.addTrack(id: "mic", label: "Mic", kind: "microphone", sampleRate: 16000, channels: 1)
        try session.append(id: "mic", pcm: Data(repeating: 1, count: 32000), offsetMs: 0)
        try session.finish()
        try MeetingMetadataWriter(directory: session.directory, id: session.manifest.id).transaction {
            $0["transcript"] = ["status": "done", "reference": ["kind": "sidecar", "file": "transcript.json", "format": "cassini.words.v1"]]
            $0["speakers"] = [
                ["id": "spk-1", "name": "Silvio", "provenance": "user", "colourIndex": 0],
                ["id": "spk-2", "name": "Barista", "provenance": "user", "colourIndex": 1],
            ]
        }
        let items: [[String: Any]] = [
            ["speaker": "spk-1", "startMs": 0, "endMs": 800, "text": "Roadmap deadline Friday"],
            ["speaker": "spk-2", "startMs": 1200, "endMs": 2000, "text": "Cappuccino oatmilk ready"],
        ]
        try JSONSerialization.data(withJSONObject: ["language": "en", "items": items])
            .write(to: session.directory.appendingPathComponent("transcript.json"))
        return (root, try #require(LibraryScanner(root: root).meeting(at: session.directory)))
    }

    @Test func searchOmitsBackgroundVoicesAndInvalidatesCacheOnToggle() async throws {
        let (root, initial) = try makeMeeting()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = root.appendingPathComponent("cache")
        let index = try SearchIndex(cache: cache)

        // Before marking background: both speakers appear in names and search.
        #expect(SearchIndex.names([initial]) == ["Barista", "Silvio"])
        try await index.replace([initial])
        #expect(try await index.search("cappuccino").count == 1)
        #expect(try await index.search("roadmap").count == 1)

        // Mark spk-2 as background: omitted from names and search, cache invalidated (bug class #3).
        try SpeakerEdits.apply(.batch([.init(speaker: "spk-2", background: true)]), to: initial, roots: [root])
        let withBackground = try #require(LibraryScanner(root: root).meeting(at: initial.folder))
        #expect(SearchIndex.names([withBackground]) == ["Silvio"])
        try await index.replace([withBackground])
        #expect(try await index.search("cappuccino").isEmpty)
        let roadmapHits = try await index.search("roadmap")
        #expect(roadmapHits.count == 1)
        #expect(roadmapHits[0].context.allSatisfy { $0.turn.speaker != "spk-2" })

        // Switch background back off: searchable again.
        try SpeakerEdits.apply(.batch([.init(speaker: "spk-2", background: false)]), to: withBackground, roots: [root])
        let restored = try #require(LibraryScanner(root: root).meeting(at: initial.folder))
        #expect(SearchIndex.names([restored]) == ["Barista", "Silvio"])
        try await index.replace([restored])
        #expect(try await index.search("cappuccino").count == 1)
    }
}
