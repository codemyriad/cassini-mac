// SPDX-License-Identifier: GPL-3.0-or-later
import CassiniLibrary
import Foundation
import Testing

@Suite struct D108PlayerTimeTests {
    @Test func underOneHourUsesUnpaddedMinutesAndTwoDigitSeconds() {
        let locale = Locale(identifier: "en_GB")
        let duration: Int64 = 2_154_000 // 35:54
        #expect(LibraryFormat.playerTime(0, durationMs: duration, locale: locale) == "0:00")
        #expect(LibraryFormat.playerTime(1_000, durationMs: duration, locale: locale) == "0:01")
        #expect(LibraryFormat.playerTime(872_000, durationMs: duration, locale: locale) == "14:32")
        #expect(LibraryFormat.playerTime(duration, durationMs: duration, locale: locale) == "35:54")
        #expect(LibraryFormat.playerTime(-5_000, durationMs: duration, locale: locale) == "0:00")
        #expect(LibraryFormat.playerTime(3_599_000, durationMs: 3_599_000, locale: locale) == "59:59")
    }

    @Test func oneHourOrLongerUsesUnpaddedHoursWithTwoDigitMinutesAndSeconds() {
        let locale = Locale(identifier: "en_GB")
        let exactHour: Int64 = 3_600_000 // 1:00:00
        #expect(LibraryFormat.playerTime(0, durationMs: exactHour, locale: locale) == "0:00:00")
        #expect(LibraryFormat.playerTime(1_000, durationMs: exactHour, locale: locale) == "0:00:01")
        #expect(LibraryFormat.playerTime(exactHour, durationMs: exactHour, locale: locale) == "1:00:00")

        let overHour: Int64 = 3_780_000 // 1:03:00
        #expect(LibraryFormat.playerTime(1_000, durationMs: overHour, locale: locale) == "0:00:01")
        #expect(LibraryFormat.playerTime(872_000, durationMs: overHour, locale: locale) == "0:14:32")
        #expect(LibraryFormat.playerTime(overHour, durationMs: overHour, locale: locale) == "1:03:00")
    }

    @Test func turnPositionsKeepZeroPaddedHoursMinutesSeconds() {
        let locale = Locale(identifier: "en_GB")
        #expect(LibraryFormat.position(872_000, locale: locale, language: .en) == "00:14:32")
        #expect(LibraryFormat.position(1_000, locale: locale, language: .en) == "00:00:01")
    }

    @Test func d108CatalogStringsResolve() {
        let locale = Locale(identifier: "en_GB")
        #expect(LibraryLocalization.shared.text("search.field.placeholder", language: .en, locale: locale) == "Search every meeting")
        #expect(LibraryLocalization.shared.text("meeting.find.position", ["index": "2", "count": "3"], language: .en, locale: locale) == "2 of 3")
        #expect(LibraryLocalization.shared.text("meeting.moveToRecentlyDeleted", language: .en, locale: locale) == "Move to Recently Deleted")
    }
}
