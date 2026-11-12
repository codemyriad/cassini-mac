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
    @Test(arguments:["unknown-major","damaged-manifest"])
    func unreadableCassiniDoesNotBorrowDATE(_ kind: String) throws {
        let fixture = try Fixture()
        let base = try Data(contentsOf:fixture.repository.appendingPathComponent("Tests/CassiniKitTests/Conformance/opus/027-recorded-at-utc.opus"))
        let original = try #require(CassiniReader.read(base).tags)
        var comments = original.comments.filter { $0.name != "DATE" }
        comments.append(.init(name:"DATE",value:"2001-02-03T04:05:06+01:00"))
        let tag = kind == "unknown-major" ? "CASSINI_FORMAT" : "CASSINI_PAYLOAD_SHA256"
        comments.removeAll { $0.name == tag }
        comments.append(.init(name:tag,value:kind == "unknown-major" ? "org.cassini.portable-meeting/999" : String(repeating:"0",count:64)))
        let source = fixture.root.appendingPathComponent(kind + ".opus")
        _ = try OpusStreamFile.rewrite(base,tags:PortableMeetingTags.packet(comments:comments),to:source)
        let file = try CassiniReader.read(contentsOf:source)
        #expect(file.state == (kind == "unknown-major" ? .unknownCassiniFormat : .invalidCassiniMetadata))
        #expect(file.meetingTime == nil)
        let opened = MeetingPresentation.external(file,url:source)
        #expect(opened.meetingTime == nil)
        let imported = try LibraryImport.copy(source,into:fixture.root.appendingPathComponent("Imported"))
        #expect(imported.meetingTime == nil)
        let rebuilt = try #require(LibraryScanner(root:imported.folder.deletingLastPathComponent()).scan().meetings.first)
        #expect(rebuilt.meetingTime == nil)
        #expect(!MeetingMarkdown.render(rebuilt,timeZone:TimeZone(secondsFromGMT:0)!,language:.en).contains("03:05"))
        if let output = ProcessInfo.processInfo.environment["CASSINI_D95_REVIEW_CASES"] {
            let directory = URL(fileURLWithPath:output); try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
            try Data(contentsOf:source).write(to:directory.appendingPathComponent(kind + ".opus"))
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
    @Test func mixedRecordingAndCreationTimesFormUniqueLocalizedSections() throws {
        let fixture=try Fixture()
        let path=fixture.repository.appendingPathComponent("Tests/CassiniKitTests/Conformance/opus/027-recorded-at-utc.opus")
        let file=try CassiniReader.read(contentsOf:path)
        let now=try #require(MeetingTime.parseInstant("2026-11-09T12:00:00Z"))
        func item(_ title:String,_ at:String?) -> LibraryMeeting {
            var value=MeetingPresentation.external(file,url:path)
            value.title=title;value.recordedTime=nil
            value.start=at.flatMap(MeetingTime.parseInstant)
            return value
        }
        let a=item("First today","2026-11-09T11:00:00Z"),b=item("Second today","2026-11-09T09:00:00Z")
        let u=item("Unknown one",nil),v=item("Unknown two",nil)
        let y=item("Yesterday","2026-11-08T23:00:00Z")
        let format=LibraryFormat(timeZone:TimeZone(secondsFromGMT:0)!,now:now,locale:Locale(identifier:"en_GB"),language:.en)
        let groups=LibraryScan(meetings:[a,u,b,y,v],issues:[]).groups(format:format)
        #expect(groups.count==3)
        #expect(Set(groups.map(\.id)).count==groups.count)
        #expect(groups.first?.meetings.map(\.title)==["First today","Second today"])
        #expect(groups.last?.meetings.map(\.title)==["Unknown one","Unknown two"])
        #expect(Set(groups.map(\.title)).count==groups.count)
        let french=LibraryFormat(timeZone:format.timeZone,now:now,locale:Locale(identifier:"en_US"),language:.fr)
        let localized=LibraryScan(meetings:[u,v],issues:[]).groups(format:french)
        #expect(localized.first?.title==LibraryLocalization.shared.text("library.group.unknownDate",language:.fr,locale:french.locale))
        #expect(localized.first?.title != "Date unknown")
        #expect(localized.first?.id==groups.last?.id)
        #expect(LibraryNames.dateTagInstant("2026-11-09t12:00:00z")==now)
    }

}
