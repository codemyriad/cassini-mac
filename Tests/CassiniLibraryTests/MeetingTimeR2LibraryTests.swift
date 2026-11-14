// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
import CassiniKit
@testable import CassiniLibrary

struct MeetingTimeR2LibraryTests {
    private func vector(_ name:String) throws -> (URL,CassiniFile) {
        let repo=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let url=repo.appendingPathComponent("Tests/CassiniKitTests/Conformance/opus/"+name+".opus")
        return (url,try CassiniReader.read(contentsOf:url))
    }
    @Test func mixedCivilAndSubmillisecondInstantsHaveOneTotalOrder() throws {
        var manifest=try #require(vector("028-date-is-created-at").1.manifest?.meeting)
        manifest.recordedAtUtc=nil;manifest.recordedAtLocal="2026-11-09T10:00:00"
        let civil=try #require(MeetingTime.resolve(meeting:manifest,dateTag:nil))
        let base=try #require(MeetingTime.parseInstant("2026-11-09T10:00:00Z"))
        func item(_ digit:Int,_ time:MeetingTime) -> LibraryMeeting {
            let id=UUID(uuidString:"00000000-0000-4000-8000-00000000000"+String(digit))!
            var m=LibraryMeeting(id:id,folder:URL(fileURLWithPath:"/tmp/Recording-"+id.uuidString.lowercased()),state:.init(),title:String(digit),start:time.instant,durationMs:nil,speakers:[],quote:nil,notes:[],audioFiles:[],issues:[])
            m.recordedTime=time;return m
        }
        let a=item(1,MeetingTime(instant:base.addingTimeInterval(0.0001))),b=item(3,MeetingTime(instant:base.addingTimeInterval(0.0004))),c=item(2,civil)
        #expect(LibraryScanner.ordered(b,a) && LibraryScanner.ordered(a,c) && LibraryScanner.ordered(b,c))
        for input in [[a,b,c],[a,c,b],[b,a,c],[b,c,a],[c,a,b],[c,b,a]] {
            #expect(input.sorted(by:LibraryScanner.ordered).map(\.title)==["3","1","2"])
        }
    }
    @Test func exactFractionOrderingDoesNotFallBackToRoundedDate() throws {
        var manifest=try #require(vector("028-date-is-created-at").1.manifest?.meeting)
        manifest.recordedAtLocal=nil
        func item(_ digit:Int,_ value:String) throws -> LibraryMeeting {
            manifest.recordedAtUtc=value
            let time=try #require(MeetingTime.resolve(meeting:manifest,dateTag:nil))
            let id=UUID(uuidString:"00000000-0000-4000-8000-00000000000"+String(digit))!
            var m=LibraryMeeting(id:id,folder:URL(fileURLWithPath:"/tmp/Recording-"+id.uuidString.lowercased()),state:.init(),title:String(digit),start:time.instant,durationMs:nil,speakers:[],quote:nil,notes:[],audioFiles:[],issues:[])
            m.recordedTime=time;return m
        }
        let a=try item(1,"2026-11-09T10:00:00.0000000001Z"),b=try item(3,"2026-11-09T10:00:00.0000000009Z")
        #expect(a.sortingInstant==b.sortingInstant,"Foundation display dates cannot represent this difference")
        #expect(LibraryScanner.ordered(b,a) && !LibraryScanner.ordered(a,b))
    }
    @Test(arguments:CassiniLanguage.allCases)
    func unknownDateKeepsDurationProvenanceAndHitPosition(_ language:CassiniLanguage) throws {
        let locale=Locale(identifier:"en_US"),format=LibraryFormat(timeZone:TimeZone(secondsFromGMT:0)!,locale:locale,language:language)
        let unknown=LibraryLocalization.shared.text("library.group.unknownDate",language:language,locale:locale)
        let received=LibraryLocalization.shared.text("states.badge.received",language:language,locale:locale)
        let duration=LibraryFormat.meetingDuration(3_120_000,locale:locale,language:language)
        let preview=format.previewSubtitle(nil as MeetingTime?,durationMs:3_120_000,received:true)
        #expect(preview.contains(unknown) && preview.contains(duration) && preview.contains(received))
        #expect(!preview.contains("{time}") && !preview.contains(", ·"))
        let context=format.searchContext(nil as MeetingTime?,durationMs:3_120_000,positionMs:872_000)
        #expect(context.contains(unknown) && context.contains(duration) && context.contains(LibraryFormat.position(872_000,locale:locale,language:language)))
        #expect(format.searchDate(nil as MeetingTime?)==unknown)
        #expect(format.previewSubtitle(nil as MeetingTime?,durationMs:nil,received:true).contains(received))
    }
    @Test(arguments:["not-a-date","2026-02-30T10:00:00","2001-02-03T04:05:06Z","2001-02-03T04:05:06+09:00"])
    func malformedCivilFilesShowUnknownAndSortByFallback(_ label:String) throws {
        let (url,base)=try vector("028-date-is-created-at")
        var manifest=try #require(base.manifest?.raw),info=try #require(manifest["meeting"])
        info=try info.setting("recordedAtUtc",to:nil).setting("recordedAtLocal",to:.string(label))
        manifest=try manifest.setting("meeting",to:info)
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);defer {try? FileManager.default.removeItem(at:root)}
        let target=root.appendingPathComponent("invalid-local.opus")
        _=try OpusStreamFile.rewrite(Data(contentsOf:url),tags:PortableMeetingTags.make(manifest:manifest,transcripts:PortableMeetingTags.transcripts(own:nil,carried:base)),to:target)
        let file=try CassiniReader.read(contentsOf:target)
        let opened=MeetingPresentation.external(file,url:target)
        let imported=try LibraryImport.copy(target,into:root.appendingPathComponent("Library"))
        let rebuilt=try #require(LibraryScanner(root:imported.folder.deletingLastPathComponent()).scan().meetings.first)
        let format=LibraryFormat(timeZone:TimeZone(secondsFromGMT:0)!,locale:Locale(identifier:"en_GB"),language:.en)
        for meeting in [opened,imported,rebuilt] {
            #expect(meeting.meetingTime==nil && meeting.start==nil)
            let fallback=try #require(meeting.sortingFallback)
            #expect(meeting.timeSortKey==MeetingTime.sortKey(for:fallback))
            var known=meeting;known.start=fallback.addingTimeInterval(-60)
            #expect(LibraryScanner.ordered(meeting,known) && !LibraryScanner.ordered(known,meeting))
            #expect(LibraryScan(meetings:[meeting],issues:[]).groups(format:format).first?.title=="Date unknown")
            let subtitle=format.previewSubtitle(meeting.meetingTime,durationMs:meeting.durationMs,received:true)
            #expect(subtitle.contains("Date unknown") && subtitle.contains("Imported") && !subtitle.contains(label))
        }
    }
    @Test func quickLookDateAssemblyUsesTheSharedRecordingTime() throws {
        let format=LibraryFormat(timeZone:TimeZone(secondsFromGMT:-12*3600)!,locale:Locale(identifier:"en_GB"),language:.en)
        let known=try #require(MeetingTime.parseInstant("2026-11-09T09:31:48.250Z"))
        for name in ["027-recorded-at-utc","029-date-with-offset"] {
            let file=try vector(name).1
            #expect(format.quickLookRecordingDate(file)==[format.absoluteDate(known)])
        }
        let local=try vector("028-date-is-created-at").1
        let civilFormat=LibraryFormat(timeZone:TimeZone(secondsFromGMT:0)!,locale:format.locale,language:.en)
        #expect(format.quickLookRecordingDate(local)==[civilFormat.absoluteDate(known)])
        let (url,base)=try vector("028-date-is-created-at")
        var manifest=try #require(base.manifest?.raw),meeting=try #require(manifest["meeting"])
        meeting=try meeting.setting("recordedAtLocal",to:nil).setting("recordedAtUtc",to:nil)
        manifest=try manifest.setting("meeting",to:meeting)
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);defer {try? FileManager.default.removeItem(at:root)}
        let target=root.appendingPathComponent("creation.opus")
        _=try OpusStreamFile.rewrite(Data(contentsOf:url),tags:PortableMeetingTags.make(manifest:manifest,transcripts:PortableMeetingTags.transcripts(own:nil,carried:base)),to:target)
        #expect(format.quickLookRecordingDate(try CassiniReader.read(contentsOf:target)).isEmpty)
    }
}
