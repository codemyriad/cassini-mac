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
}
