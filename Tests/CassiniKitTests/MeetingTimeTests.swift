// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import CassiniKit

struct RecordingTimeReaderTests {
    private func file(_ name: String) throws -> CassiniFile {
        let root = try #require(Bundle.module.url(forResource:"Conformance",withExtension:nil))
        return try CassiniReader.read(contentsOf:root.appendingPathComponent("opus/" + name + ".opus"))
    }
    @Test(arguments:[("027-recorded-at-utc","recordedAtUtc","2026-11-09T09:31:48.250Z"),
                     ("028-date-is-created-at","recordedAtLocal","2026-11-09T09:31:48"),
                     ("029-date-with-offset","DATE","2026-11-09T10:31:48+01:00")])
    func normativeVectors(vector: String, source: String, value: String) throws {
        let file = try file(vector)
        #expect(file.state == .ok && file.errors.isEmpty && file.warnings.isEmpty)
        #expect(file.meetingTime?.source.rawValue == source)
        #expect(file.meetingTime?.value == value)
        if source == "recordedAtLocal" { #expect(file.meetingTime?.instant == nil) }
        else { #expect(file.meetingTime?.instant == MeetingTime.parseInstant(value)) }
    }
    @Test(arguments:["2026-11-09T10:47:02Z","2026-11-09T11:47:02+01:00","2026-11-09T10:47:02.000Z"])
    func equivalentArtifactStampsAreNotRecordingTimes(_ tag: String) throws {
        var meeting = try #require(file("028-date-is-created-at").manifest?.meeting)
        #expect(MeetingTime.resolve(meeting:meeting,dateTag:tag)?.source == .recordedAtLocal)
        meeting.recordedAtLocal = nil
        #expect(MeetingTime.resolve(meeting:meeting,dateTag:tag) == nil)
    }
    @Test(arguments:["2026-11-09T09:31:48","2026-11-09T09:31:48-00:00","bad date"])
    func datesWithoutKnownOffsetsDoNotNameInstants(_ tag: String) throws {
        let meeting = try #require(file("028-date-is-created-at").manifest?.meeting)
        #expect(MeetingTime.resolve(meeting:meeting,dateTag:tag)?.source == .recordedAtLocal)
    }
    @Test func utcMirrorDisagreementIsReported() throws {
        let file = try file("027-recorded-at-utc")
        var tags = try #require(file.tags); tags.comments.removeAll { $0.name.uppercased() == "CASSINI_RECORDED_AT_UTC" }
        tags.comments.append(.init(name:"CASSINI_RECORDED_AT_UTC",value:"2020-01-01T00:00:00Z"))
        var warnings: [Finding] = []
        CassiniReader.compareCopies(try #require(file.manifest),TagSet(vendor:tags.vendor,comments:tags.comments),&warnings)
        #expect(warnings.contains { $0.code == "tag-manifest-disagreement" && $0.tag == "CASSINI_RECORDED_AT_UTC" })
    }
    @Test(arguments:["2026-11-09t09:31:48.250Z","2026-11-09T09:31:48.250z","2026-11-09t09:31:48.250z"])
    func lowercaseRFC3339RecordingTimesAreInstants(_ value:String) throws {
        var meeting=try #require(file("027-recorded-at-utc").manifest?.meeting)
        meeting.recordedAtUtc=value
        let expected=try #require(MeetingTime.parseInstant("2026-11-09T09:31:48.250Z"))
        #expect(MeetingTime.parseInstant(value)==expected)
        #expect(MeetingTime.resolve(meeting:meeting,dateTag:nil)?.instant==expected)
        #expect(MeetingTime.resolve(meeting:meeting,dateTag:nil)?.source == .recordedAtUtc)
        #expect(MeetingTime.resolve(meeting:meeting,dateTag:nil)?.value==value)
    }
    @Test(arguments:["2026-11-09T10:47:02Z","2026-11-09t11:47:02+01:00","2026-11-09t10:47:02.000z"])
    func lowercaseCreationTimesNeverLeakThroughDATE(_ tag:String) throws {
        var meeting=try #require(file("028-date-is-created-at").manifest?.meeting)
        meeting.createdAtUtc="2026-11-09t10:47:02z";meeting.recordedAtLocal=nil
        #expect(MeetingTime.resolve(meeting:meeting,dateTag:tag)==nil)
        #expect(MeetingTime.dateTag(recordedAtUtc:nil,createdAtUtc:meeting.createdAtUtc,legacy:tag)==meeting.createdAtUtc)
    }

}

extension RecordingTimeReaderTests {
    @Test(arguments:["2026-02-30T09:00:00Z","2026-11-09T24:00:00Z","2026-11-09T09:60:00Z","2026-11-09T09:00:60Z","2026-02-29T09:00:00Z","2026-11-09T09:00:00+24:00","2026-11-09T09:00:00+00:60","0000-01-01T00:00:00Z"])
    func impossibleInstantsCannotOverrideAValidDATE(_ value:String) throws {
        var meeting=try #require(file("027-recorded-at-utc").manifest?.meeting)
        meeting.recordedAtUtc=value
        #expect(MeetingTime.parseInstant(value)==nil)
        #expect(MeetingTime.normalizedUTC(value)==nil)
        let fallback="2026-11-09T10:31:48.250+01:00"
        let time=MeetingTime.resolve(meeting:meeting,dateTag:fallback)
        #expect(time?.source == .date && time?.value==fallback)
    }
    @Test func fractionalCreationComparisonDoesNotRoundToMilliseconds() throws {
        var meeting=try #require(file("028-date-is-created-at").manifest?.meeting)
        meeting.recordedAtUtc=nil;meeting.recordedAtLocal=nil
        meeting.createdAtUtc="2026-11-09T09:31:48.0001Z"
        let distinct="2026-11-09T09:31:48.0009Z"
        #expect(MeetingTime.resolve(meeting:meeting,dateTag:distinct)?.value==distinct)
        #expect(MeetingTime.dateTag(recordedAtUtc:nil,createdAtUtc:meeting.createdAtUtc,legacy:distinct)==distinct)
        for equivalent in ["2026-11-09T09:31:48.0001000Z","2026-11-09T10:31:48.000100+01:00"] {
            #expect(MeetingTime.resolve(meeting:meeting,dateTag:equivalent)==nil)
            #expect(MeetingTime.dateTag(recordedAtUtc:nil,createdAtUtc:meeting.createdAtUtc,legacy:equivalent)==meeting.createdAtUtc)
        }
    }
    @Test(arguments:["2026-11-09 10:31:48+01:00"," \t2026-11-09t10:31:48+01:00\r\n","2026-11-09 09:31:48z"])
    func legacyDATEAcceptsReferenceSeparatorsAndTrimsItsValue(_ value:String) throws {
        var meeting=try #require(file("028-date-is-created-at").manifest?.meeting)
        meeting.recordedAtUtc=nil;meeting.recordedAtLocal=nil
        let time=MeetingTime.resolve(meeting:meeting,dateTag:value)
        #expect(time?.source == .date)
        #expect(time?.value==value.trimmingCharacters(in:.whitespacesAndNewlines))
        meeting.createdAtUtc=" 2026-11-09 09:31:48Z "
        #expect(MeetingTime.resolve(meeting:meeting,dateTag:value)==nil)
    }
    @Test(arguments:["not-a-date","2026-02-30T10:00:00","2026-11-09T24:00:00","2026-11-09T09:00:00Z","2026-11-09T09:00:00+01:00"])
    func malformedCivilLabelsNeverBecomeMeetingTime(_ value:String) throws {
        var meeting=try #require(file("028-date-is-created-at").manifest?.meeting)
        meeting.recordedAtUtc=nil;meeting.recordedAtLocal=value
        #expect(MeetingTime.resolve(meeting:meeting,dateTag:meeting.createdAtUtc)==nil)
    }
    @Test(arguments:[
        ("2026-11-09 09:31:48.123456789Z","2026-11-09T09:31:48.123456789Z"),
        (" \t2026-11-09 09:31:48.000123456789z\r\n","2026-11-09T09:31:48.000123456789Z"),
    ])
    func referenceReaderRecordedAtUtcFormsResolveWithoutFallback(_ pair:(String,String)) throws {
        var meeting=try #require(file("028-date-is-created-at").manifest?.meeting)
        meeting.recordedAtUtc=pair.0;meeting.recordedAtLocal=nil
        #expect(MeetingTime.normalizedUTC(pair.0)==pair.1)
        let resolved=MeetingTime.resolve(meeting:meeting,dateTag:meeting.createdAtUtc)
        #expect(resolved?.source == .recordedAtUtc)
        #expect(resolved?.value==pair.0.trimmingCharacters(in:.whitespacesAndNewlines))
        #expect(resolved?.orderingKey==MeetingTime.resolve(meeting:{ var m=meeting; m.recordedAtUtc=pair.1; return m }(),dateTag:meeting.createdAtUtc)?.orderingKey)
    }
}
