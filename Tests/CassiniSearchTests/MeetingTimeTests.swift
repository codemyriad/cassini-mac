// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
import CassiniKit
import CassiniLibrary
import CassiniSearch

struct MeetingTimeSearchTests {
    @Test(arguments:[("America/Sao_Paulo","2018-11-04T15:00:00Z","2018-11-04T03:00:00Z","2018-11-05T02:00:00Z","2018-10-29T03:00:00Z"),
                     ("America/Havana","2015-03-08T15:00:00Z","2015-03-08T05:00:00Z","2015-03-09T04:00:00Z","2015-03-02T05:00:00Z")])
    func midnightDSTUsesCalendarDayBounds(zoneID: String, nowText: String, firstText: String, endText: String, weekText: String) throws {
        let zone = try #require(TimeZone(identifier:zoneID))
        let now = try #require(MeetingTime.parseInstant(nowText))
        let first = try #require(MeetingTime.parseInstant(firstText))
        let end = try #require(MeetingTime.parseInstant(endText))
        let week = try #require(MeetingTime.parseInstant(weekText))
        for (instant,expected) in [(first.addingTimeInterval(-0.001),false),(first,true),(end.addingTimeInterval(-0.001),true),(end,false)] {
            #expect(SearchDate.today.contains(meetingTime:MeetingTime(instant:instant),now:now,timeZone:zone) == expected)
        }
        #expect(SearchDate.week.contains(meetingTime:MeetingTime(instant:week),now:now,timeZone:zone))
        #expect(!SearchDate.week.contains(meetingTime:MeetingTime(instant:week.addingTimeInterval(-0.001)),now:now,timeZone:zone))
    }
    @Test(arguments:["Etc/GMT-14","GMT+0530","EST5EDT","America/St_Johns","current"])
    func viewerDateAndClockUseTheSameZone(_ zoneID: String) throws {
        let zone = try #require(zoneID == "current" ? TimeZone.current : TimeZone(identifier:zoneID))
        let instant = try #require(MeetingTime.parseInstant("2026-11-09T23:45:00Z"))
        var calendar = Calendar(identifier:.gregorian); calendar.timeZone = zone
        let c = calendar.dateComponents([.year,.month,.day,.hour,.minute],from:instant)
        let clock = String(format:"%02d:%02d",try #require(c.hour),try #require(c.minute))
        let format = LibraryFormat(timeZone:zone,now:instant,locale:Locale(identifier:"en_GB"),language:.en)
        let time = MeetingTime(instant:instant)
        #expect(format.rowTime(time) == clock)
        #expect(format.dayGroup(time) == "Today")
        let utc = try #require(TimeZone(secondsFromGMT:0))
        var scaffold = Calendar(identifier:.gregorian); scaffold.timeZone = utc
        let civilDate = try #require(scaffold.date(from:DateComponents(year:c.year,month:c.month,day:c.day)))
        let expectedDate = LibraryFormat(timeZone:utc,locale:Locale(identifier:"en_GB"),language:.en).absoluteDate(civilDate)
        #expect(format.absoluteDate(time) == expectedDate)
        #expect(format.absoluteDateLine(time,durationMs:nil) == expectedDate + ", " + clock)
    }
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
