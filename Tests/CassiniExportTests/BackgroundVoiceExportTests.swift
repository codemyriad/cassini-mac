// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import CassiniKit
import CassiniLibrary
import CassiniRecording
@testable import CassiniExport

/// D112 (L-86) / D-1169: Background voices are omitted from Plain text / SRT / WebVTT
/// exports, and preserved verbatim in x["codemyriad.io"].meeting.speakers across .opus
/// export and re-import (while manifest speakers[] keeps all speakers).
struct BackgroundVoiceExportTests {
    private func makeMeeting() throws -> (URL, LibraryMeeting) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BgExport-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let session = try RecordingSession(parent: root, title: "Project sync", source: "macos")
        try session.addTrack(id: "mic", label: "Me", kind: "microphone", sampleRate: 16000, channels: 1)
        try session.appendNative(id: "mic", pcm: Data(repeating: 1, count: 64000), offsetMs: 0)
        try session.finish()
        let items: [[String: Any]] = [
            ["speaker": "spk-1", "startMs": 0, "endMs": 400, "text": "Hello"],
            ["speaker": "spk-2", "startMs": 500, "endMs": 900, "text": "Background chatter"],
            ["speaker": "spk-1", "startMs": 1000, "endMs": 1500, "text": "Goodbye"],
        ]
        try JSONSerialization.data(withJSONObject: ["language": "en", "items": items], options: [.sortedKeys])
            .write(to: session.directory.appendingPathComponent("transcript.json"))
        try MeetingMetadataWriter(directory: session.directory, id: session.manifest.id).transaction { metadata in
            metadata["transcript"] = ["status": "done", "reference": ["kind": "sidecar", "file": "transcript.json", "format": "cassini.words.v1"], "model": "whistle"]
            metadata["speakers"] = [
                ["id": "spk-1", "name": "Sam", "provenance": "user", "colourIndex": 0],
                ["id": "spk-2", "name": "Marta", "provenance": "user", "colourIndex": 1, "background": true],
            ]
        }
        return (root, try #require(LibraryScanner(root: root).scan().meetings.first))
    }

    @Test func textAndSubtitleExportsOmitBackgroundVoices() throws {
        let (root, meeting) = try makeMeeting()
        defer { try? FileManager.default.removeItem(at: root) }

        for kind: MeetingExportKind in [.plainText, .srt, .vtt] {
            let rendered = try MeetingTextExport.render(meeting, kind: kind)
            #expect(rendered.contains("Sam"))
            #expect(rendered.contains("Hello"))
            #expect(rendered.contains("Goodbye"))
            #expect(!rendered.contains("Marta"))
            #expect(!rendered.contains("Background chatter"))
        }
    }

    @Test func codemyriadNamespacePreservesAndPropagatesBackgroundFlag() throws {
        let (root, meeting) = try makeMeeting()
        defer { try? FileManager.default.removeItem(at: root) }
        let stored = try #require(try CodemyriadNamespace.current(meeting))
        let ns = try #require(try CodemyriadNamespace.make(meeting, stored: stored, dateTag: nil, originalTitle: nil, now: Date(), zone: .current))
        let xSpeakers = try #require(ns["meeting"]?["speakers"]?.array)
        let spk2 = try #require(xSpeakers.first { $0["id"]?.string == "spk-2" })
        #expect(spk2["background"] == .bool(true))
        #expect(spk2["name"]?.string == "Marta")

        // Now turn background off on Mac and verify CodemyriadNamespace.merged removes it.
        try SpeakerEdits.apply(.batch([.init(speaker: "spk-2", background: false)]), to: meeting, roots: [root])
        let updated = try #require(LibraryScanner(root: root).meeting(at: meeting.folder))
        let merged = try CodemyriadNamespace.merged(ns, with: updated, originalNotes: nil)
        let mergedSpk2 = try #require(merged.namespace["meeting"]?["speakers"]?.array?.first { $0["id"]?.string == "spk-2" })
        #expect(mergedSpk2["background"] == nil)
        #expect(mergedSpk2["name"]?.string == "Marta")
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["CASSINI_OPUS_ASSETS"] != nil))
    func opusExportRoundTripsBackgroundVoiceThroughReimport() throws {
        let (root, meeting) = try makeMeeting()
        defer { try? FileManager.default.removeItem(at: root) }
        let assetsURL = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["CASSINI_OPUS_ASSETS"]))
        let hashes = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: assetsURL.appendingPathComponent("unsigned-sha256.json")))
        let assets = try OpusAssets.builtForTests(directory: assetsURL, expectedBinarySHA256: #require(hashes["libopus.0.dylib"]))
        let artifact = try MeetingFileExporter.cassini(meeting, assets: assets, temporaryRoot: root)
        let file = try CassiniReader.read(contentsOf: artifact.url)
        #expect(file.state == .ok)
        // Manifest speakers[] keeps all speakers including background voices (MAPPING.md).
        #expect(file.manifest?.speakers.map(\.id) == ["spk-1", "spk-2"])
        // External open reads background: true from x["codemyriad.io"].meeting.speakers.
        let external = MeetingPresentation.external(file, url: artifact.url)
        #expect(external.speaker(for: "spk-2")?.background == true)
        #expect(external.speaker(for: "spk-1")?.background == false)
        // Importing the .opus preserves background: true.
        let imported = try LibraryImport.copy(artifact.url, into: root.appendingPathComponent("Imported"))
        #expect(imported.speaker(for: "spk-2")?.background == true)
        #expect(!imported.speakerNames.contains("Marta"))
    }
}
