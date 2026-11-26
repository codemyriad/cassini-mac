// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
import CassiniKit
@testable import CassiniLibrary

@Suite struct QAFixesTests {
    @Test func smallExportsUseKBAndKeepTheExistingMBBoundary() {
        #expect(LibraryFormat.size(bytes:0) == "0 KB")
        #expect(LibraryFormat.size(bytes:458 * 1024,approximate:true) == "about 458 KB")
        #expect(LibraryFormat.size(bytes:1_048_575) == "1 MB")
        #expect(LibraryFormat.size(bytes:1_048_576) == "1 MB")
    }
    @Test func wallTimesRespectTheLocaleWhilePlaybackPositionsStayDurations() throws {
        let zone = try #require(TimeZone(secondsFromGMT:0))
        let date = Date(timeIntervalSince1970:13 * 3600 + 5 * 60)
        let british = LibraryFormat(timeZone:zone,now:date,locale:Locale(identifier:"en_GB"),language:.en)
        let american = LibraryFormat(timeZone:zone,now:date,locale:Locale(identifier:"en_US"),language:.en)
        #expect(british.rowTime(date) == "13:05")
        #expect(american.rowTime(date).contains("1:05"))
        #expect(american.rowTime(date).contains("PM"))
        #expect(american.previewSubtitle(date,durationMs:300000).contains("PM"))
        #expect(LibraryFormat.position(13 * 3600000 + 5 * 60000) == "13:05:00")
        let markdown = MeetingMarkdown.render(title:"Meeting",start:date,durationMs:nil,timeZone:zone,names:[:],items:[],notes:[],locale:Locale(identifier:"en_US"))
        #expect(markdown.contains("1:05") && markdown.contains("PM"))
    }
    @Test func compactPositionDropsHoursUnderAnHourAndKeepsThemAtAnHour() {
        let locale = Locale(identifier: "en_GB")
        #expect(LibraryFormat.compactPosition(12_000, durationMs: 900_000, padMinutes: true, locale: locale) == "00:12")
        #expect(LibraryFormat.compactPosition(14 * 60_000 + 32_000, durationMs: 1_800_000, padMinutes: true, locale: locale) == "14:32")
        #expect(LibraryFormat.compactPosition(11_000, durationMs: 900_000, padMinutes: false, locale: locale) == "0:11")
        #expect(LibraryFormat.compactPosition(1_000, padMinutes: false, locale: locale) == "0:01")
        #expect(LibraryFormat.compactPosition(3600_000 + 2 * 60_000 + 15_000, durationMs: 4_000_000, padMinutes: true, locale: locale) == "1:02:15")
        #expect(LibraryFormat.compactPosition(12_000, durationMs: 3600_000, padMinutes: true, locale: locale) == "0:00:12")
    }
    @Test func previewSubtitlePartsSplitsDatePrefixFromTrailingMetadata() throws {
        let zone = try #require(TimeZone(secondsFromGMT: 0))
        let date = Date(timeIntervalSince1970: 13 * 3600 + 5 * 60)
        let format = LibraryFormat(timeZone: zone, now: date, locale: Locale(identifier: "en_GB"), language: .en)
        let known = format.previewSubtitleParts(MeetingTime(instant: date), durationMs: 2_520_000, received: false)
        #expect(known.date == "Today, 13:05")
        #expect(known.suffix == " · 42 min")
        let unknown = format.previewSubtitleParts(nil, durationMs: 600_000, received: true)
        #expect(unknown.date == "Date unknown")
        #expect(unknown.suffix.contains("10 min"))
    }
    @Test func newMacQAStringsResolveInAllSupportedLanguages() {
        let keys = [
            "mac.details.source.recorded",
            "mac.details.source.silent",
            "mac.details.source.gap",
            "mac.details.source.computerBusy",
            "mac.details.source.neverAudio",
            "mac.details.source.lowAudio",
            "mac.details.source.lowAudio.underSecond",
            "mac.details.source.failed",
            "mac.details.source.notSelected",
            "mac.speakers.underSecond",
            "mac.imported.notTranscribed",
        ]
        let locale = Locale(identifier: "en_GB")
        for language: CassiniLanguage in [.en, .it, .fr, .es, .ptBR, .ptPT] {
            for key in keys {
                let rendered = LibraryLocalization.shared.text(key, ["duration": "12 s"], language: language, locale: locale)
                #expect(!rendered.isEmpty && rendered != key)
            }
        }
    }
}
