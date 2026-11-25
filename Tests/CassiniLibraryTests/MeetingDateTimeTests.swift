// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
import CassiniKit
@testable import CassiniLibrary

@Suite struct MeetingDateTimeTests {
    private func plainOpusFixture() throws -> URL {
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return repo.appendingPathComponent("Tests/CassiniKitTests/Conformance/opus/002-plain-audio.opus")
    }

    @Test func startedAtValidationFollowsQ17AndSchema() throws {
        for good in [
            "2026-11-23T14:36:00Z",
            "2026-11-23T14:36:00+00:00",
            "2026-11-23T14:36:00+01:00",
            "2026-11-23T14:36:00-00:01",
            "2026-11-23T14:36:00-12:00",
            "2026-11-23T14:36:00+14:00",
        ] {
            #expect(MeetingTime.isValidStartedAt(good), "expected valid: \(good)")
            #expect(MeetingTime.userStartedAt(good) != nil)
        }
        for bad in [
            "2026-11-23T14:36:00-00:00",
            "2026-11-23T14:36:00-12:01",
            "2026-11-23T14:36:00+14:01",
            "2026-11-23T14:36:00.500Z",
            "2026-02-30T14:36:00+01:00",
            "2026-11-23 14:36:00+01:00",
            "not-a-date",
        ] {
            #expect(!MeetingTime.isValidStartedAt(bad), "expected invalid: \(bad)")
            #expect(MeetingTime.userStartedAt(bad) == nil)
        }
    }

    @Test func schemaEnforcesDependentRequiredOnStartedAtPair() throws {
        let id = UUID()
        func parse(_ extra: [String: Any]) throws -> AppMetadata {
            var doc = MeetingMetadataWriter.defaultDocument(id: id)
            for (k, v) in extra { doc[k] = v }
            let data = try JSONSerialization.data(withJSONObject: doc)
            let parsed = try AppMetadata.parse(data)
            try parsed.validate(id: id, received: false)
            return parsed
        }
        _ = try parse(["startedAt": "2026-11-23T14:36:00+01:00", "startedAtSource": "user"])
        #expect(throws: Error.self) { _ = try parse(["startedAt": "2026-11-23T14:36:00+01:00"]) }
        #expect(throws: Error.self) { _ = try parse(["startedAtSource": "user"]) }
        #expect(throws: Error.self) { _ = try parse(["startedAt": "2026-11-23T14:36:00-00:00", "startedAtSource": "user"]) }
        #expect(throws: Error.self) { _ = try parse(["startedAt": "2026-11-23T14:36:00+01:00", "startedAtSource": "import"]) }
    }

    @Test func prefillUsesRecordingTimeThenFileSavedTimeMinusLengthThenNow() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cassini-dt-prefill-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let zone = try #require(TimeZone(secondsFromGMT: 3600))
        let now = try #require(MeetingTime.parseInstant("2026-11-24T12:00:00Z"))

        // 1. Imported file with no recording time: preserves source mtime and prefills mtime - duration.
        let source = root.appendingPathComponent("gadget-clip.opus")
        try FileManager.default.copyItem(at: try plainOpusFixture(), to: source)
        let savedAt = try #require(MeetingTime.parseInstant("2026-11-23T14:12:00Z")) // 15:12 +01:00
        try FileManager.default.setAttributes([.modificationDate: savedAt], ofItemAtPath: source.path)

        let imported = try LibraryImport.copy(source, into: root.appendingPathComponent("Library"))
        #expect(imported.meetingTime == nil)
        let filePrefill = MeetingDateTime.prefill(for: imported, now: now, timeZone: zone)
        #expect(filePrefill.fromFileSavedTime == true)
        let expectedDuration = Double(imported.durationMs ?? 0) / 1000.0
        #expect(abs(filePrefill.date.timeIntervalSince(savedAt.addingTimeInterval(-expectedDuration))) < 1.0)

        // 2. After setting a recording date, prefill uses the recording time with no hint.
        let chosen = try #require(MeetingTime.parseInstant("2026-11-23T13:36:00Z")) // 14:36 +01:00
        try MeetingDateTime.apply(chosen, timeZone: zone, to: imported)
        let updated = try #require(LibraryScanner(root: root.appendingPathComponent("Library")).meeting(at: imported.folder))
        let existingPrefill = MeetingDateTime.prefill(for: updated, now: now, timeZone: zone)
        #expect(existingPrefill.fromFileSavedTime == false)
        #expect(abs(existingPrefill.date.timeIntervalSince(chosen)) < 0.5)

        // 3. No recording time and no audio file: falls back to now with no hint.
        var empty = updated
        empty.start = nil
        empty.recordedTime = nil
        empty.userStartedAt = nil
        empty.audioFiles = []
        let fallbackPrefill = MeetingDateTime.prefill(for: empty, now: now, timeZone: zone)
        #expect(fallbackPrefill.fromFileSavedTime == false)
        #expect(fallbackPrefill.date == now)
    }

    @Test func settingDateMovesUnknownImportedMeetingOutOfDateUnknownWithoutRenamingFolder() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cassini-dt-move-" + UUID().uuidString)
        let library = root.appendingPathComponent("Library")
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let zone = try #require(TimeZone(secondsFromGMT: 3600))
        let now = try #require(MeetingTime.parseInstant("2026-11-24T12:00:00Z"))
        let format = LibraryFormat(timeZone: zone, now: now, locale: Locale(identifier: "en_GB"), language: .en)

        let imported = try LibraryImport.copy(try plainOpusFixture(), into: library)
        let originalFolderName = imported.folder.lastPathComponent
        let scanner = LibraryScanner(root: library)

        let beforeGroups = try scanner.scan(now: now).groups(format: format)
        #expect(beforeGroups.map(\.title) == ["Date unknown"])

        let yesterday = try #require(MeetingTime.parseInstant("2026-11-23T13:36:00Z")) // 14:36 +01:00
        try MeetingDateTime.apply(yesterday, timeZone: zone, to: imported)

        let afterScan = try scanner.scan(now: now)
        let afterGroups = afterScan.groups(format: format)
        #expect(afterGroups.map(\.title) == ["Yesterday"])
        #expect(!afterGroups.contains { $0.title == "Date unknown" })
        let updated = try #require(afterScan.meetings.first)
        #expect(updated.folder.lastPathComponent == originalFolderName)
        #expect(updated.userStartedAt == "2026-11-23T14:36:00+01:00")
        #expect(updated.meetingTime?.instant == yesterday)
        let subtitle = format.previewSubtitle(updated.meetingTime, durationMs: updated.durationMs, received: true)
        #expect(subtitle.contains("Yesterday, 14:36"))
        #expect(!subtitle.contains("Date unknown"))
        let markdown = MeetingMarkdown.render(updated, timeZone: zone, locale: Locale(identifier: "en_GB"), language: .en)
        #expect(markdown.contains("23 November 2026"))
        #expect(markdown.contains("14:36"))
    }

    @Test func legacyImportTimeSynthesizedDateIsExcludedUntilUserSetsDate() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cassini-dt-legacy-" + UUID().uuidString)
        let library = root.appendingPathComponent("Library")
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // Build a plain opus with a legacy synthesized DATE tag, then mark meeting.json with namePrefixSource = import-time.
        let tagged = root.appendingPathComponent("legacy.opus")
        _ = try OpusStreamFile.rewrite(
            Data(contentsOf: try plainOpusFixture()),
            tags: PortableMeetingTags.packet(comments: [.init(name: "DATE", value: "2026-11-24T09:15:00+01:00")]),
            to: tagged
        )
        let imported = try LibraryImport.copy(tagged, into: library)
        try MeetingMetadataWriter(directory: imported.folder, id: imported.id).transaction {
            $0["namePrefix"] = "2026-11-24--09.15-"
            $0["namePrefixSource"] = "import-time"
        }

        let scanner = LibraryScanner(root: library)
        let zone = try #require(TimeZone(secondsFromGMT: 3600))
        let now = try #require(MeetingTime.parseInstant("2026-11-24T12:00:00Z"))
        let format = LibraryFormat(timeZone: zone, now: now, locale: Locale(identifier: "en_GB"), language: .en)

        let before = try scanner.scan(now: now)
        #expect(before.meetings.first?.meetingTime == nil)
        #expect(before.groups(format: format).map(\.title) == ["Date unknown"])

        let chosen = try #require(MeetingTime.parseInstant("2026-11-23T13:36:00Z"))
        try MeetingDateTime.apply(chosen, timeZone: zone, to: try #require(before.meetings.first))

        let after = try scanner.scan(now: now)
        #expect(after.meetings.first?.userStartedAt == "2026-11-23T14:36:00+01:00")
        #expect(after.groups(format: format).map(\.title) == ["Yesterday"])
    }
}
