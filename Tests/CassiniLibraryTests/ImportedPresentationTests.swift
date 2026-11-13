// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
import CassiniKit
@testable import CassiniLibrary

struct ImportedPresentationTests {
    @Test func subtitleAttributesOnlyTheTranscriptCarriedByAnImportedFile() {
        let date = Date(timeIntervalSince1970: 0)
        let format = LibraryFormat(timeZone: TimeZone(secondsFromGMT: 0)!, now: date, locale: Locale(identifier: "en_GB"), language: .en)
        #expect(format.previewSubtitle(date, durationMs: 2_040_000, received: true, transcriptFromImportedFile: true) ==
                "Today, 00:00 · 34 min · Imported · Transcribed on another device")
        #expect(format.previewSubtitle(date, durationMs: 2_040_000, received: true) == "Today, 00:00 · 34 min · Imported")
        #expect(format.previewSubtitle(date, durationMs: 2_040_000, transcriptFromImportedFile: true) == "Today, 00:00 · 34 min")
    }

    @Test func importedProvenancePreservesCivilAndUnknownRecordingTimes() throws {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let file = try CassiniReader.read(contentsOf: repository.appendingPathComponent("Tests/CassiniKitTests/Conformance/opus/028-date-is-created-at.opus"))
        var meeting = try #require(file.manifest?.meeting)
        meeting.recordedAtUtc = nil; meeting.recordedAtLocal = "2026-10-23T15:00:00"
        let civil = try #require(MeetingTime.resolve(meeting: meeting, dateTag: nil))
        let now = try #require(MeetingTime.parseInstant("2026-10-27T12:00:00Z"))
        let format = LibraryFormat(timeZone: TimeZone(identifier: "America/Los_Angeles")!, now: now, locale: Locale(identifier: "en_GB"), language: .en)
        #expect(format.previewSubtitle(civil, durationMs: 2_040_000, received: true, transcriptFromImportedFile: true) ==
                "Friday 23 October, 15:00 · 34 min · Imported · Transcribed on another device")
        #expect(format.previewSubtitle(nil as MeetingTime?, durationMs: nil, received: true, transcriptFromImportedFile: true) ==
                "Date unknown · Imported · Transcribed on another device")
    }
}
