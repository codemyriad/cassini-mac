// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
import CassiniKit
@testable import CassiniLibrary

struct MeetingTimeTests {
    @Test(arguments:["027-recorded-at-utc","028-date-is-created-at","029-date-with-offset"])
    func recordingTimeSurvivesOpeningImportAndCatalogueRebuild(_ vector: String) throws {
        let fixture = try Fixture()
        let source = fixture.repository.appendingPathComponent("Tests/CassiniKitTests/Conformance/opus/" + vector + ".opus")
        let file = try CassiniReader.read(contentsOf:source)
        #expect(file.state == .ok)
        let expected = vector.hasPrefix("028") ? nil : ISO8601DateFormatter().date(from:"2026-11-09T09:31:48Z")?.addingTimeInterval(vector.hasPrefix("027") ? 0.25 : 0)
        let opened = MeetingPresentation.external(file,url:source)
        #expect(opened.start == expected)
        let imported = try LibraryImport.copy(source,into:fixture.root.appendingPathComponent("Imported"))
        #expect(imported.start == expected)
        let rebuilt = try #require(LibraryScanner(root:imported.folder.deletingLastPathComponent()).scan().meetings.first)
        #expect(rebuilt.start == expected)
        if vector.hasPrefix("028") {
            let text = MeetingMarkdown.render(rebuilt,timeZone:TimeZone(identifier:"Asia/Tokyo")!,locale:Locale(identifier:"en_GB"),language:.en)
            #expect(text.contains("09:31"),"The local label's clock must remain as written")
            #expect(!text.contains("19:47"),"The pack stamp is never the meeting time")
        }
    }
    @Test func creationOnlyNeverBecomesTheMeetingTime() throws {
        let fixture = try Fixture()
        let base = try Data(contentsOf:fixture.repository.appendingPathComponent("Tests/CassiniKitTests/Conformance/opus/001-minimal-v1.opus"))
        var root = try #require(CassiniReader.read(base).manifest?.raw)
        var info = try #require(root["meeting"])
        info = try info.setting("recordedAtLocal",to:nil).setting("recordedAtUtc",to:nil)
        root = try root.setting("meeting",to:info)
        let tags = try PortableMeetingTags.make(manifest:root,transcript:Data("{\"items\":[]}".utf8),wordCount:0)
        let source = fixture.root.appendingPathComponent("Creation only.opus")
        _ = try OpusStreamFile.rewrite(base,tags:tags,to:source)
        let file = try CassiniReader.read(contentsOf:source)
        let opened = MeetingPresentation.external(file,url:source)
        let imported = try LibraryImport.copy(source,into:fixture.root.appendingPathComponent("Imported"))
        #expect(opened.start == nil)
        #expect(imported.start == nil)
        let text = MeetingMarkdown.render(imported,timeZone:TimeZone(secondsFromGMT:0)!,locale:Locale(identifier:"en_GB"),language:.en)
        let createdText = try #require(info["createdAtUtc"]?.string)
        let created = try #require(MeetingTime.parseInstant(createdText))
        let format = LibraryFormat(timeZone:TimeZone(secondsFromGMT:0)!,locale:Locale(identifier:"en_GB"),language:.en)
        #expect(!text.contains(format.absoluteDate(created)))
        #expect(imported.meetingTime == nil)
        var known = imported; known.start = created.addingTimeInterval(-9 * 60)
        #expect(LibraryScanner.ordered(imported,known),"Creation is a last sorting fallback, not a displayed time")
        #expect(LibraryScan(meetings:[imported],issues:[]).groups(format:format).first?.title == "Date unknown")
    }
}
