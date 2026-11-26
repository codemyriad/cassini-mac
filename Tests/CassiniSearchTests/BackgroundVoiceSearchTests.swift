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

    @Test func searchPromotesForegroundAsideFromBackgroundHostAndExcludesReverse() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BgSearchAside-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try RecordingSession(parent: root, title: "Aside sync", source: "macos")
        try session.addTrack(id: "mic", label: "Mic", kind: "microphone", sampleRate: 16000, channels: 1)
        try session.append(id: "mic", pcm: Data(repeating: 1, count: 32000), offsetMs: 0)
        try session.finish()
        try MeetingMetadataWriter(directory: session.directory, id: session.manifest.id).transaction {
            $0["transcript"] = ["status": "done", "reference": ["kind": "sidecar", "file": "transcript.json", "format": "cassini.words.v1"]]
            $0["speakers"] = [
                ["id": "fg", "name": "Silvio", "provenance": "user", "colourIndex": 0],
                ["id": "bg", "name": "Barista", "provenance": "user", "colourIndex": 1, "background": true],
            ]
        }
        // Arrangement 1: foreground aside ("Confirmed Tuesday.") inside background host ("Latte ready ... table three.").
        // Arrangement 2: background aside ("Espresso shot.") inside foreground host ("We ship ... release Friday.").
        let items: [[String: Any]] = [
            ["speaker": "bg", "startMs": 0, "endMs": 800, "text": "Latte"],
            ["speaker": "bg", "startMs": 800, "endMs": 2000, "text": "ready"],
            ["speaker": "fg", "startMs": 1900, "endMs": 2050, "text": "Confirmed"],
            ["speaker": "fg", "startMs": 2050, "endMs": 2200, "text": "Tuesday."],
            ["speaker": "bg", "startMs": 2100, "endMs": 2600, "text": "for"],
            ["speaker": "bg", "startMs": 2600, "endMs": 3100, "text": "table"],
            ["speaker": "bg", "startMs": 3100, "endMs": 3600, "text": "three."],
            ["speaker": "fg", "startMs": 10000, "endMs": 10800, "text": "We"],
            ["speaker": "fg", "startMs": 10800, "endMs": 12000, "text": "ship"],
            ["speaker": "bg", "startMs": 11900, "endMs": 12050, "text": "Espresso"],
            ["speaker": "bg", "startMs": 12050, "endMs": 12200, "text": "shot."],
            ["speaker": "fg", "startMs": 12100, "endMs": 12600, "text": "the"],
            ["speaker": "fg", "startMs": 12600, "endMs": 13100, "text": "release"],
            ["speaker": "fg", "startMs": 13100, "endMs": 13600, "text": "Friday."],
        ]
        try JSONSerialization.data(withJSONObject: ["language": "en", "items": items])
            .write(to: session.directory.appendingPathComponent("transcript.json"))
        let meeting = try #require(LibraryScanner(root: root).meeting(at: session.directory))
        let allTurns = MeetingPresentation.turns(meeting.transcriptItems, gaps: meeting.speakerGaps, endsBoundedByAudio: meeting.wordEndsBoundedByAudio)
        let fgAside = try #require(allTurns.first { $0.speaker == "fg" && $0.host != nil })
        let bgAside = try #require(allTurns.first { $0.speaker == "bg" && $0.host != nil })
        #expect(allTurns[fgAside.host!].speaker == "bg")
        #expect(allTurns[bgAside.host!].speaker == "fg")

        let index = try SearchIndex(cache: root.appendingPathComponent("cache"))
        try await index.replace([meeting])

        // Foreground aside inside background host is searchable with preserved speaker, seek position, and turn ID.
        let promotedHits = try await index.search("Confirmed Tuesday")
        #expect(promotedHits.count == 1)
        #expect(promotedHits[0].speaker == "fg")
        #expect(promotedHits[0].positionMs == 1900)
        #expect(promotedHits[0].text == "Confirmed Tuesday.")
        #expect(promotedHits[0].context.first { $0.index == promotedHits[0].turn }?.turn.id == fgAside.id)
        #expect(promotedHits[0].context.allSatisfy { $0.turn.speaker != "bg" })

        // Background host and background aside are both excluded from search.
        #expect(try await index.search("Latte").isEmpty)
        #expect(try await index.search("Espresso").isEmpty)

        // Foreground host with background aside stays searchable without the background aside's text.
        let hostHits = try await index.search("release Friday")
        #expect(hostHits.count == 1)
        #expect(hostHits[0].speaker == "fg")
        #expect(hostHits[0].positionMs == 12600)
        #expect(!hostHits[0].text.contains("Espresso"))
    }
}
