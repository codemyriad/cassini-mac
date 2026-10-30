// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import CassiniLibrary

@Suite struct QAFixesTests {
    @Test func smallExportsUseKBAndKeepTheExistingMBBoundary() {
        #expect(LibraryFormat.size(bytes:0) == "0 KB")
        #expect(LibraryFormat.size(bytes:458 * 1024,approximate:true) == "about 458 KB")
        #expect(LibraryFormat.size(bytes:1_048_575) == "1024 KB")
        #expect(LibraryFormat.size(bytes:1_048_576) == "1 MB")
    }
    @Test func wallTimesRespectTheLocaleWhilePlaybackPositionsStayDurations() throws {
        let zone = try #require(TimeZone(secondsFromGMT:0))
        let date = Date(timeIntervalSince1970:13 * 3600 + 5 * 60)
        let british = LibraryFormat(timeZone:zone,now:date,locale:Locale(identifier:"en_GB"))
        let american = LibraryFormat(timeZone:zone,now:date,locale:Locale(identifier:"en_US"))
        #expect(british.rowTime(date) == "13:05")
        #expect(american.rowTime(date).contains("1:05"))
        #expect(american.rowTime(date).contains("PM"))
        #expect(american.previewSubtitle(date,durationMs:300000).contains("PM"))
        #expect(LibraryFormat.position(13 * 3600000 + 5 * 60000) == "13:05:00")
        let markdown = MeetingMarkdown.render(title:"Meeting",start:date,durationMs:nil,timeZone:zone,names:[:],items:[],notes:[],locale:Locale(identifier:"en_US"))
        #expect(markdown.contains("1:05") && markdown.contains("PM"))
    }
}
