// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
import CassiniKit
import CassiniLibrary
@testable import CassiniExport

struct RecordingTimeR2ExportTests {
    private func document(root:URL,utc:String?,created:String,date:String) throws -> URL {
        let repo=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source=repo.appendingPathComponent("Tests/CassiniKitTests/Conformance/opus/027-recorded-at-utc.opus")
        let bytes=try Data(contentsOf:source),base=try CassiniReader.read(bytes)
        var manifest=try #require(base.manifest?.raw),meeting=try #require(manifest["meeting"])
        meeting=try meeting.setting("recordedAtUtc",to:utc.map(JSON.string)).setting("recordedAtLocal",to:nil).setting("createdAtUtc",to:.string(created))
        manifest=try manifest.setting("meeting",to:meeting)
        var tags=try TagSet.parse(PortableMeetingTags.make(manifest:manifest,transcripts:PortableMeetingTags.transcripts(own:nil,carried:base)))
        tags.comments.removeAll {$0.name.uppercased()=="DATE"};tags.comments.append(.init(name:"DATE",value:date))
        let input=root.appendingPathComponent("input.opus")
        _=try OpusStreamFile.rewrite(bytes,tags:PortableMeetingTags.packet(comments:tags.comments),to:input)
        return input
    }
    private func save(_ url:URL,name:String) throws {
        guard let output=ProcessInfo.processInfo.environment["CASSINI_D95_R2_CASES"] else {return}
        let target=URL(fileURLWithPath:output);try FileManager.default.createDirectory(at:target,withIntermediateDirectories:true)
        try Data(contentsOf:url).write(to:target.appendingPathComponent(name+".opus"))
    }
    @Test(arguments:["2026-02-30T09:00:00Z","2026-11-09T24:00:00Z"])
    func invalidUTCDoesNotReplaceDistinctDATEOnReadExportOrReimport(_ invalid:String) throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);defer {try? FileManager.default.removeItem(at:root)}
        let date="2026-11-09T10:31:48.250+01:00",kind=invalid.contains("02-30") ? "feb30" : "hour24"
        let input=try document(root:root,utc:invalid,created:"2026-11-09T10:47:02Z",date:date)
        let file=try CassiniReader.read(contentsOf:input)
        #expect(file.state == .ok)
        #expect(file.meetingTime?.source == .date && file.meetingTime?.value==date)
        try save(input,name:kind+"-input")
        let imported=try LibraryImport.copy(input,into:root.appendingPathComponent("Library"))
        for (i,meeting) in [MeetingPresentation.external(file,url:input),imported].enumerated() {
            let artifact=try MeetingFileExporter.cassini(meeting,assets:nil,temporaryRoot:root)
            let result=try CassiniReader.read(contentsOf:artifact.url)
            #expect(result.manifest?.meeting.recordedAtUtc==nil && result.tags?["CASSINI_RECORDED_AT_UTC"]==nil)
            #expect(result.meetingTime?.source == .date && result.meetingTime?.value==date)
            let again=try LibraryImport.copy(artifact.url,into:root.appendingPathComponent("Again-"+String(i)))
            #expect(again.meetingTime?.value==date)
            try save(artifact.url,name:kind+"-export-"+String(i))
        }
    }
    @Test(arguments:[false,true])
    func spacePaddedLegacyDATEAndCreationCompareAndExportConsistently(equivalent:Bool) throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);defer {try? FileManager.default.removeItem(at:root)}
        let created=" 2026-11-09 10:47:02z ",date=equivalent ? "2026-11-09T10:47:02Z" : " \t2026-11-09 10:31:48+01:00\r\n"
        let input=try document(root:root,utc:nil,created:created,date:date),file=try CassiniReader.read(contentsOf:input)
        #expect(file.meetingTime?.value==(equivalent ? nil : date.trimmingCharacters(in:.whitespacesAndNewlines)))
        try save(input,name:"space-\(equivalent)-input")
        let imported=try LibraryImport.copy(input,into:root.appendingPathComponent("Library"))
        let artifact=try MeetingFileExporter.cassini(imported,assets:nil,temporaryRoot:root)
        let result=try CassiniReader.read(contentsOf:artifact.url)
        #expect(result.manifest?.meeting.createdAtUtc=="2026-11-09T10:47:02Z")
        #expect(result.meetingTime?.value==(equivalent ? nil : date.trimmingCharacters(in:.whitespacesAndNewlines)))
        try save(artifact.url,name:"space-\(equivalent)-export")
    }
}
