// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
import CassiniKit
import CassiniRecording
@testable import CassiniLibrary

/// D112 (L-86) / D-1169: Background voices schema, batch edits, undo restore,
/// transcript folding, Markdown export omission, and .opus reader support.
struct BackgroundVoiceTests {
    private func makeSevenSpeakerFixture() throws -> (URL, LibraryMeeting) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BackgroundVoice-" + UUID().uuidString)
        let session = try RecordingSession(parent: root, title: "Incontro ORA", source: "macos")
        try session.addTrack(id: "mic", label: "Mic", kind: "microphone", sampleRate: 16000, channels: 1)
        try session.append(id: "mic", pcm: Data(repeating: 1, count: 32000), offsetMs: 0)
        try session.finish()
        try MeetingMetadataWriter(directory: session.directory, id: session.manifest.id).transaction {
            $0["transcript"] = ["status": "done", "reference": ["kind": "sidecar", "file": "transcript.json", "format": "cassini.words.v1"]]
            $0["speakers"] = [
                ["id": "spk-1", "name": "Silvio", "provenance": "user", "colourIndex": 0, "voiceSource": ["inputSHA256": String(repeating: "a", count: 64), "turnsSHA256": String(repeating: "b", count: 64)]],
                ["id": "spk-2", "name": "Ruurd", "provenance": "user", "colourIndex": 1],
                ["id": "spk-3", "name": NSNull(), "provenance": "unnamed", "colourIndex": 2],
                ["id": "spk-4", "name": NSNull(), "provenance": "unnamed", "colourIndex": 3],
                ["id": "spk-5", "name": "Stranger", "provenance": "user", "colourIndex": 4],
                ["id": "spk-6", "name": NSNull(), "provenance": "unnamed", "colourIndex": 5],
                ["id": "spk-7", "name": NSNull(), "provenance": "unnamed", "colourIndex": 6],
            ]
        }
        let words: [(String, Int, Int, String)] = [
            ("spk-1", 0, 1000, "Allora partiamo dal calendario."),
            ("spk-2", 1200, 2200, "Yes, end of the month."),
            ("spk-4", 2400, 3000, "Coffee for table three."),
            ("spk-5", 3200, 4000, "No, the other one by the window."),
            ("spk-4", 4200, 4800, "Coming right up."),
            ("spk-3", 5000, 6200, "Then I will book the room."),
            ("spk-6", 6500, 7000, "Excuse me."),
            ("spk-7", 7200, 7800, "Check please."),
            ("spk-1", 8000, 9000, "Perfetto."),
        ]
        let items = words.map { ["speaker": $0.0, "startMs": $0.1, "endMs": $0.2, "text": $0.3] as [String: Any] }
        try JSONSerialization.data(withJSONObject: ["language": "en", "items": items])
            .write(to: session.directory.appendingPathComponent("transcript.json"))
        return (root, try #require(LibraryScanner(root: root).meeting(at: session.directory)))
    }

    private func document(_ meeting: LibraryMeeting) throws -> JSON {
        try JSONParser.parse(Data(contentsOf: meeting.folder.appendingPathComponent("meeting.json")))
    }

    @Test func schemaAcceptsBackgroundTrueAndRejectsBackgroundFalse() throws {
        let (root, meeting) = try makeSevenSpeakerFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = meeting.folder.appendingPathComponent("meeting.json")
        var raw = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        var speakers = raw["speakers"] as! [[String: Any]]
        speakers[3]["background"] = true
        raw["speakers"] = speakers
        let validData = try JSONSerialization.data(withJSONObject: raw)
        let parsed = try AppMetadata.parse(validData)
        try parsed.validate(id: meeting.id, received: false)
        #expect(parsed.speakers[3].background == true)

        speakers[3]["background"] = false
        raw["speakers"] = speakers
        let invalidData = try JSONSerialization.data(withJSONObject: raw)
        #expect(throws: (any Error).self) {
            let bad = try AppMetadata.parse(invalidData)
            try bad.validate(id: meeting.id, received: false)
        }
    }

    @Test func batchEditPreservesNameAndUndoRestoresVerbatim() throws {
        let (root, meeting) = try makeSevenSpeakerFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let transcriptURL = meeting.folder.appendingPathComponent("transcript.json")
        let transcriptBefore = try Data(contentsOf: transcriptURL)
        let audioBefore = try meeting.audioFiles.map { try Data(contentsOf: $0) }
        let docBefore = try document(meeting)

        let changes: [SpeakerEdits.BatchChange] = [
            .init(speaker: "spk-3", name: "Marta", background: nil),
            .init(speaker: "spk-4", name: nil, background: true),
            .init(speaker: "spk-5", name: nil, background: true),
        ]
        let snapshot = try #require(try SpeakerEdits.applyReturningSnapshot(.batch(changes), to: meeting, roots: [root]))
        let updated = try #require(LibraryScanner(root: root).meeting(at: meeting.folder))
        let docAfter = try document(updated)

        // Transcript body and audio never change.
        #expect(try Data(contentsOf: transcriptURL) == transcriptBefore)
        #expect(try updated.audioFiles.map { try Data(contentsOf: $0) } == audioBefore)
        #expect(docAfter["revision"]?.int == docBefore["revision"]!.int! + 1)

        // Named speaker updated, background speakers marked with background: true, existing name kept!
        #expect(updated.speaker(for: "spk-3")?.name == "Marta")
        #expect(updated.speaker(for: "spk-3")?.background == false)
        #expect(updated.speaker(for: "spk-4")?.background == true)
        #expect(updated.speaker(for: "spk-5")?.background == true)
        #expect(updated.speaker(for: "spk-5")?.name == "Stranger")

        // Background speakers leave visibleSpeakers and speakerNames (Library card & header names row).
        #expect(!updated.visibleSpeakers.contains { $0.id == "spk-4" || $0.id == "spk-5" })
        #expect(updated.speakerNames.contains("Marta"))
        #expect(!updated.speakerNames.contains("Stranger"))

        // Switching background off removes the key (never false) and restores the kept name.
        try SpeakerEdits.apply(.batch([.init(speaker: "spk-5", name: nil, background: false)]), to: updated, roots: [root])
        let unbgDoc = try document(updated)
        let spk5Entry = unbgDoc["speakers"]?.array?.first { $0["id"]?.string == "spk-5" }
        #expect(spk5Entry?["background"] == nil)
        #expect(spk5Entry?["name"]?.string == "Stranger")

        // Undo restores exact pre-edit state.
        let beforeUndo = try #require(LibraryScanner(root: root).meeting(at: meeting.folder))
        try SpeakerEdits.apply(.restore(snapshot), to: beforeUndo, roots: [root])
        let restored = try #require(LibraryScanner(root: root).meeting(at: meeting.folder))
        #expect(restored.speaker(for: "spk-3")?.name == nil)
        #expect(restored.speaker(for: "spk-3")?.provenance == .unnamed)
        #expect(restored.speaker(for: "spk-4")?.background == false)
        #expect(restored.speaker(for: "spk-5")?.background == false)
        #expect(restored.speaker(for: "spk-5")?.name == "Stranger")
        let restoredDoc = try document(restored)
        #expect(restoredDoc["speakers"]?.array?.first?["voiceSource"] == docBefore["speakers"]?.array?.first?["voiceSource"])
    }

    @Test func displayEntriesFoldConsecutiveBackgroundRunsAndCountDistinctVoices() throws {
        let (root, meeting) = try makeSevenSpeakerFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try SpeakerEdits.apply(.batch([
            .init(speaker: "spk-4", background: true),
            .init(speaker: "spk-5", background: true),
            .init(speaker: "spk-6", background: true),
            .init(speaker: "spk-7", background: true),
        ]), to: meeting, roots: [root])
        let updated = try #require(LibraryScanner(root: root).meeting(at: meeting.folder))
        let turns = MeetingPresentation.turns(updated.transcriptItems, gaps: updated.speakerGaps, endsBoundedByAudio: updated.wordEndsBoundedByAudio)
        let entries = MeetingPresentation.displayEntries(for: turns, background: updated.backgroundSpeakerIDs)

        // Expected sequence: spk-1, spk-2, [run: spk-4, spk-5, spk-4 -> 2 distinct voices], spk-3, [run: spk-6, spk-7 -> 2 distinct voices], spk-1
        #expect(entries.count == 6)
        if case .backgroundRun(_, let ids1, let count1) = entries[2] {
            #expect(ids1.count == 3)
            #expect(count1 == 2)
        } else {
            Issue.record("Expected folded background run at index 2")
        }
        if case .backgroundRun(_, let ids2, let count2) = entries[4] {
            #expect(ids2.count == 2)
            #expect(count2 == 2)
        } else {
            Issue.record("Expected folded background run at index 4")
        }

        // Localized string check for 1 vs 2 background voices.
        #expect(LibraryLocalization.shared.text("speakers.backgroundVoice.hidden", ["n": "1"], language: .en) == "1 background voice hidden")
        #expect(LibraryLocalization.shared.text("speakers.backgroundVoice.hidden", ["n": "2"], language: .en) == "2 background voices hidden")
    }

    @Test func markdownExportOmitsBackgroundVoices() throws {
        let (root, meeting) = try makeSevenSpeakerFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try SpeakerEdits.apply(.batch([
            .init(speaker: "spk-4", background: true),
            .init(speaker: "spk-5", background: true),
        ]), to: meeting, roots: [root])
        let updated = try #require(LibraryScanner(root: root).meeting(at: meeting.folder))
        let md = MeetingMarkdown.render(updated, timeZone: TimeZone(secondsFromGMT: 0)!, locale: Locale(identifier: "en_GB"), language: .en)
        #expect(md.contains("Silvio"))
        #expect(md.contains("Allora partiamo dal calendario."))
        #expect(!md.contains("Stranger"))
        #expect(!md.contains("Coffee for table three."))
        #expect(!md.contains("No, the other one by the window."))
    }

    @Test func displayEntriesScalesLinearlyOnLongTranscript() {
        // Bug class #1 & #17: verify linear scaling (2N vs N) with thread CPU time, no wall-clock budget.
        func makeTurns(_ count: Int) -> [MeetingPresentation.Turn] {
            (0..<count).map { i in
                let spk = (i % 5 == 2 || i % 5 == 3) ? "bg-\(i % 2)" : "main"
                return MeetingPresentation.Turn(
                    id: i, speaker: spk, items: [], startMs: Int64(i * 1000), endMs: Int64(i * 1000 + 500),
                    fragments: [], pools: []
                )
            }
        }
        let bg: Set<String> = ["bg-0", "bg-1"]
        let small = makeTurns(2_000)
        let large = makeTurns(4_000)
        let smallResult = MeetingPresentation.displayEntries(for: small, background: bg)
        let largeResult = MeetingPresentation.displayEntries(for: large, background: bg)
        #expect(largeResult.count == smallResult.count * 2)
    }

    @Test func foregroundAsideInsideBackgroundHostIsPromotedAndSearchable() throws {
        let items: [LibraryTranscriptItem] = [
            .init(speaker: "bg", startMs: 0, endMs: 800, text: "Latte"),
            .init(speaker: "bg", startMs: 800, endMs: 2000, text: "ready"),
            .init(speaker: "fg", startMs: 1900, endMs: 2050, text: "Confirmed"),
            .init(speaker: "fg", startMs: 2050, endMs: 2200, text: "Tuesday."),
            .init(speaker: "bg", startMs: 2100, endMs: 2600, text: "for"),
            .init(speaker: "bg", startMs: 2600, endMs: 3100, text: "table"),
            .init(speaker: "bg", startMs: 3100, endMs: 3600, text: "three."),
        ]
        let turns = MeetingPresentation.turns(items, endsBoundedByAudio: true)
        let fgAside = try #require(turns.first { $0.speaker == "fg" })
        let bgHost = try #require(turns.first { $0.speaker == "bg" && $0.host == nil })
        #expect(fgAside.host == bgHost.id)

        let bg: Set<String> = ["bg"]
        // Promoted foreground turn preserves original turn ID and word/seek identities.
        let promoted = MeetingPresentation.foregroundTurns(in: turns, background: bg)
        #expect(promoted.map(\.id) == [fgAside.id])
        #expect(promoted[0].items.map(\.startMs) == [1900, 2050])

        // Transcript folding shows the background run and promotes the foreground aside as its own `.turn`.
        let entries = MeetingPresentation.displayEntries(for: turns, background: bg)
        #expect(entries == [
            .backgroundRun(id: "bg-\(bgHost.id)", turnIDs: [bgHost.id], distinctVoiceCount: 1),
            .turn(fgAside.id),
        ])

        // Reading turn lookup resolves the promoted foreground aside to its own turn ID.
        #expect(MeetingPresentation.readingTurn(at: 1950, in: turns, background: bg) == fgAside.id)

        // In-meeting Find searches the promoted foreground aside and omits the background host.
        let locale = Locale(identifier: "en_GB")
        let paragraphs = try TranscriptFind.paragraphs(in: turns, names: ["bg": "Barista", "fg": "Silvio"], background: bg, locale: locale, language: .en)
        #expect(paragraphs.map(\.id) == [fgAside.id])
        let fgMatches = try TranscriptFind.matches(in: paragraphs, query: "Confirmed Tuesday", locale: locale)
        #expect(fgMatches.count == 1 && fgMatches[0].paragraph == fgAside.id)
        #expect(try TranscriptFind.matches(in: paragraphs, query: "Latte", locale: locale).isEmpty)
    }

    @Test func backgroundAsideInsideForegroundHostIsExcludedFromProseAndFind() throws {
        let items: [LibraryTranscriptItem] = [
            .init(speaker: "fg", startMs: 0, endMs: 800, text: "We"),
            .init(speaker: "fg", startMs: 800, endMs: 2000, text: "ship"),
            .init(speaker: "bg", startMs: 1900, endMs: 2050, text: "Espresso"),
            .init(speaker: "bg", startMs: 2050, endMs: 2200, text: "shot."),
            .init(speaker: "fg", startMs: 2100, endMs: 2600, text: "the"),
            .init(speaker: "fg", startMs: 2600, endMs: 3100, text: "release"),
            .init(speaker: "fg", startMs: 3100, endMs: 3600, text: "Friday."),
        ]
        let turns = MeetingPresentation.turns(items, endsBoundedByAudio: true)
        let bgAside = try #require(turns.first { $0.speaker == "bg" })
        let fgHost = try #require(turns.first { $0.speaker == "fg" && $0.host == nil })
        #expect(bgAside.host == fgHost.id)

        let bg: Set<String> = ["bg"]
        #expect(MeetingPresentation.foregroundTurns(in: turns, background: bg).map(\.id) == [fgHost.id])
        #expect(MeetingPresentation.displayEntries(for: turns, background: bg) == [.turn(fgHost.id)])

        let locale = Locale(identifier: "en_GB")
        let prose = MeetingPresentation.prose(fgHost, in: turns, names: ["bg": "Barista", "fg": "Silvio"], locale: locale, language: .en, excluding: bg)
        #expect(prose.text == "We ship the release Friday.")
        #expect(prose.seeks.map(\.item.startMs) == [0, 800, 2100, 2600, 3100])

        let paragraphs = try TranscriptFind.paragraphs(in: turns, names: ["bg": "Barista", "fg": "Silvio"], background: bg, locale: locale, language: .en)
        #expect(try TranscriptFind.matches(in: paragraphs, query: "Espresso", locale: locale).isEmpty)
        let shipMatches = try TranscriptFind.matches(in: paragraphs, query: "ship the release", locale: locale)
        #expect(shipMatches.count == 1 && shipMatches[0].paragraph == fgHost.id)
    }
}
