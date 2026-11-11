// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
import CassiniKit
import CassiniLibrary
import CassiniSearch

struct MeetingTimeSearchTests {
    @Test func civilLabelKeepsItsClockAndViewerCalendarDay() throws {
        let repository = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        var meeting = try #require(CassiniReader.read(contentsOf:repository.appendingPathComponent("Tests/CassiniKitTests/Conformance/opus/028-date-is-created-at.opus")).manifest?.meeting)
        meeting.recordedAtLocal = "2026-11-09T00:15:00"
        let time = try #require(MeetingTime.resolve(meeting:meeting,dateTag:meeting.createdAtUtc))
        let now = try #require(MeetingTime.parseInstant("2026-11-08T23:30:00Z"))
        let rome = try #require(TimeZone(identifier:"Europe/Rome"))
        #expect(SearchDate.today.contains(meetingTime:time,now:now,timeZone:rome))
        for zone in [rome,try #require(TimeZone(identifier:"America/Los_Angeles"))] {
            #expect(LibraryFormat(timeZone:zone,now:now,locale:Locale(identifier:"en_GB"),language:.en).rowTime(time) == "00:15")
        }
        #expect(time.instant == nil)
        #expect(!SearchDate.today.contains(meetingTime:nil,now:now,timeZone:rome))
        #expect(SearchDate.any.contains(meetingTime:nil,now:now,timeZone:rome))
    }
}
