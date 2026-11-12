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
    @Test func plainDATEPromotionRetainsAllFractionalDigits() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);defer {try? FileManager.default.removeItem(at:root)}
        let repo=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let original=repo.appendingPathComponent("Tests/CassiniKitTests/Conformance/opus/002-plain-audio.opus")
        let date="2026-11-09 10:31:48.000900000001+01:00",utc="2026-11-09T09:31:48.000900000001Z"
        let input=root.appendingPathComponent("plain.opus")
        _=try OpusStreamFile.rewrite(Data(contentsOf:original),tags:PortableMeetingTags.packet(comments:[.init(name:"DATE",value:date)]),to:input)
        let file=try CassiniReader.read(contentsOf:input)
        #expect(file.state == .plainAudio && file.meetingTime?.value==date)
        let imported=try LibraryImport.copy(input,into:root.appendingPathComponent("Library"))
        for (i,meeting) in [MeetingPresentation.external(file,url:input),imported].enumerated() {
            let artifact=try MeetingFileExporter.cassini(meeting,assets:nil,temporaryRoot:root)
            let result=try CassiniReader.read(contentsOf:artifact.url)
            #expect(result.manifest?.meeting.recordedAtUtc==utc)
            #expect(result.manifest?.meeting.createdAtUtc==utc)
            #expect(result.tags?["DATE"]==utc && result.tags?["CASSINI_RECORDED_AT_UTC"]==utc)
            let again=try LibraryImport.copy(artifact.url,into:root.appendingPathComponent("Again-"+String(i)))
            #expect(again.meetingTime?.value==utc)
            try save(artifact.url,name:"plain-fraction-export-"+String(i))
        }
    }
    @Test(arguments:["not-a-date","2026-02-30T10:47:02Z"])
    func invalidCreationRepairKeepsTheKnownDATE(_ created:String) throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);defer {try? FileManager.default.removeItem(at:root)}
        let date="2026-11-09T10:31:48.250+01:00",utc="2026-11-09T09:31:48.250Z"
        let input=try document(root:root,utc:nil,created:created,date:date),before=try Data(contentsOf:input)
        let file=try CassiniReader.read(before),kind=created=="not-a-date" ? "bad" : "impossible"
        #expect(file.state == .ok && file.meetingTime?.value==date)
        try save(input,name:"creation-"+kind+"-input")
        let imported=try LibraryImport.copy(input,into:root.appendingPathComponent("Library"))
        for (i,meeting) in [MeetingPresentation.external(file,url:input),imported].enumerated() {
            let artifact=try MeetingFileExporter.cassini(meeting,assets:nil,temporaryRoot:root)
            let result=try CassiniReader.read(contentsOf:artifact.url)
            #expect(result.manifest?.meeting.recordedAtUtc==utc)
            #expect(result.manifest?.meeting.createdAtUtc==utc)
            #expect(result.tags?["DATE"]==utc && result.tags?["CASSINI_RECORDED_AT_UTC"]==utc)
            let again=try LibraryImport.copy(artifact.url,into:root.appendingPathComponent("Again-"+String(i)))
            #expect(again.meetingTime?.value==utc)
            #expect(result.manifest?.meeting.id==file.manifest?.meeting.id && result.audioDigest==file.audioDigest)
            try save(artifact.url,name:"creation-"+kind+"-export-"+String(i))
        }
        #expect(try Data(contentsOf:input)==before)
    }

    enum TimestampRepairKind: String, CaseIterable, Sendable {
        case normalizedCreated
        case invalidCreatedWithDate
        case lowercaseRecordedUtc
        case invalidRecordedUtc
        case invalidRecordedLocal
        case equivalentDateReplaced
        case invalidDateReplaced
        case staleCreatedTag
    }

    private func namespacedDocument(root: URL, kind: TimestampRepairKind?, revision: String = "7") throws -> URL {
        let repo = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = repo.appendingPathComponent("Tests/CassiniKitTests/Conformance/opus/027-recorded-at-utc.opus")
        let bytes = try Data(contentsOf:source), base = try CassiniReader.read(bytes)
        var manifest = try #require(base.manifest?.raw), meeting = try #require(manifest["meeting"])
        let cleanCreated = "2026-11-09T10:47:02Z"
        let cleanRecorded = "2026-11-09T09:31:48.250Z"
        let cleanLocal = "2026-11-09T10:31:48"
        var created = cleanCreated
        var recorded: String? = cleanRecorded
        var local: String? = cleanLocal
        var customDate: String?
        var customCreatedTag: String?
        switch kind {
        case nil:
            break
        case .normalizedCreated:
            created = " 2026-11-09 10:47:02z "
        case .invalidCreatedWithDate:
            created = "not-a-date"
            recorded = nil
            customDate = "2026-11-09T10:31:48.250+01:00"
        case .lowercaseRecordedUtc:
            recorded = "2026-11-09t09:31:48.250z"
        case .invalidRecordedUtc:
            recorded = "2026-02-30T09:00:00Z"
        case .invalidRecordedLocal:
            local = "2026-11-09T10:31:48Z"
        case .equivalentDateReplaced:
            recorded = nil
            customDate = "2026-11-09T11:47:02+01:00"
        case .invalidDateReplaced:
            recorded = nil
            customDate = "not-a-date"
        case .staleCreatedTag:
            customCreatedTag = "2020-01-01T00:00:00Z"
        }
        meeting = try meeting
            .setting("createdAtUtc",to:.string(created))
            .setting("recordedAtUtc",to:recorded.map(JSON.string))
            .setting("recordedAtLocal",to:local.map(JSON.string))
        let namespace = try JSONParser.parse(Data("""
        {"schema":1,"sessionId":"8B7D3C2E-5f1a-4c9e-9a6b-1d2e3f4a5b6c","origin":"Recording","namePrefix":"2026-11-09--10.31-","namePrefixSource":"recorded","revision":\(revision),\
        "meeting":{"version":1,"title":"Sync","titleSource":"user","speakers":[],"transcript":{"status":"none","reference":null},"etaMinutes":null,"error":null,"quoteOverride":null,"received":null,"recordingDetails":null},\
        "automaticTitle":"Sync"}
        """.utf8))
        let notes = try JSONParser.parse(Data(#"[{"atMs":1200,"text":"keep","id":"n-keep"}]"#.utf8))
        manifest = try manifest
            .setting("meeting",to:meeting)
            .setting("x",to:.object([("codemyriad.io",namespace),("gocassini.com",.object([("notes",notes)]))]))
        var tags = try TagSet.parse(PortableMeetingTags.make(manifest:manifest,transcripts:PortableMeetingTags.transcripts(own:nil,carried:base)))
        if let customDate {
            tags.comments.removeAll { $0.name.uppercased() == "DATE" }
            tags.comments.append(.init(name:"DATE",value:customDate))
        }
        if let customCreatedTag {
            tags.comments.removeAll { $0.name.uppercased() == "CASSINI_CREATED_AT" }
            tags.comments.append(.init(name:"CASSINI_CREATED_AT",value:customCreatedTag))
        }
        let output = root.appendingPathComponent("namespaced-\(kind?.rawValue ?? "clean")-\(revision).opus")
        _ = try OpusStreamFile.rewrite(bytes,tags:PortableMeetingTags.packet(comments:tags.comments),to:output)
        return output
    }

    @Test(arguments:TimestampRepairKind.allCases)
    func timestampRepairsAdvanceCodemyriadRevisionAndRemainStable(kind: TimestampRepairKind) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true); defer { try? FileManager.default.removeItem(at:root) }
        let input = try namespacedDocument(root:root,kind:kind,revision:"7")
        let sourceFile = try CassiniReader.read(contentsOf:input)
        #expect(sourceFile.state == .ok)
        let expectedNotes = try JSONParser.parse(Data(#"[{"atMs":1200,"text":"keep","id":"n-keep"}]"#.utf8))

        // 1. Direct-open export advances 7 -> 8, keeps sessionId & notes, and stays stable at 8.
        let external = MeetingPresentation.external(sourceFile,url:input)
        let direct1 = try MeetingFileExporter.cassini(external,assets:nil,temporaryRoot:root)
        let directFile1 = try CassiniReader.read(contentsOf:direct1.url)
        let directX1 = try #require(directFile1.manifest?.raw["x"]?["codemyriad.io"])
        #expect(directX1["sessionId"]?.string == "8B7D3C2E-5f1a-4c9e-9a6b-1d2e3f4a5b6c")
        #expect(directX1["revision"] == .number("8"))
        #expect(directFile1.manifest?.raw["x"]?["gocassini.com"]?["notes"] == expectedNotes)

        let direct2 = try MeetingFileExporter.cassini(external,assets:nil,temporaryRoot:root)
        let directFile2 = try CassiniReader.read(contentsOf:direct2.url)
        #expect(directFile2.manifest?.raw["x"]?["codemyriad.io"]?["revision"] == .number("8"))

        // Re-opening the repaired file directly goes out byte-for-byte at revision 8.
        let directReopened = MeetingPresentation.external(directFile1,url:direct1.url)
        let direct3 = try MeetingFileExporter.cassini(directReopened,assets:nil,temporaryRoot:root)
        #expect(try Data(contentsOf:direct3.url) == Data(contentsOf:direct1.url))

        // 2. Library export advances 7 -> 8 on repair, stays at 8 on repeated unchanged exports,
        //    and advances to 9 on a subsequent user edit.
        let libraryRoot = root.appendingPathComponent("Library")
        _ = try LibraryImport.copy(input,into:libraryRoot)
        func scanMeeting() throws -> LibraryMeeting {
            try #require(LibraryScanner(root:libraryRoot).scan().meetings.first)
        }
        let lib1 = try MeetingFileExporter.cassini(try scanMeeting(),assets:nil,temporaryRoot:root)
        let libFile1 = try CassiniReader.read(contentsOf:lib1.url)
        let libX1 = try #require(libFile1.manifest?.raw["x"]?["codemyriad.io"])
        #expect(libX1["sessionId"]?.string == "8B7D3C2E-5f1a-4c9e-9a6b-1d2e3f4a5b6c")
        #expect(libX1["revision"] == .number("8"))
        #expect(libFile1.manifest?.raw["x"]?["gocassini.com"]?["notes"] == expectedNotes)

        let lib2 = try MeetingFileExporter.cassini(try scanMeeting(),assets:nil,temporaryRoot:root)
        let libFile2 = try CassiniReader.read(contentsOf:lib2.url)
        #expect(libFile2.manifest?.raw["x"]?["codemyriad.io"]?["revision"] == .number("8"))

        // Importing the already-repaired export into another Library keeps revision 8 unchanged.
        let secondLib = root.appendingPathComponent("SecondLibrary")
        let reimported = try LibraryImport.copy(lib1.url,into:secondLib)
        let reexported = try MeetingFileExporter.cassini(reimported,assets:nil,temporaryRoot:root)
        let reexportedFile = try CassiniReader.read(contentsOf:reexported.url)
        #expect(reexportedFile.manifest?.raw["x"]?["codemyriad.io"]?["revision"] == .number("8"))

        try MeetingRename.apply("Renamed after repair",to:try scanMeeting())
        let lib3 = try MeetingFileExporter.cassini(try scanMeeting(),assets:nil,temporaryRoot:root)
        let libFile3 = try CassiniReader.read(contentsOf:lib3.url)
        #expect(libFile3.manifest?.raw["x"]?["codemyriad.io"]?["revision"] == .number("9"))
    }

    @Test func timestampRepairAtRevisionCeilingIsRefusedInLibraryAndDirectOpen() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true); defer { try? FileManager.default.removeItem(at:root) }
        let ceiling = "9007199254740991"

        // Clean file at the ceiling still exports unchanged on both paths.
        let clean = try namespacedDocument(root:root,kind:nil,revision:ceiling)
        let cleanFile = try CassiniReader.read(contentsOf:clean)
        let cleanDirect = try MeetingFileExporter.cassini(MeetingPresentation.external(cleanFile,url:clean),assets:nil,temporaryRoot:root)
        #expect(try Data(contentsOf:cleanDirect.url) == Data(contentsOf:clean))
        let cleanImported = try LibraryImport.copy(clean,into:root.appendingPathComponent("CleanLib"))
        let cleanLibExport = try MeetingFileExporter.cassini(cleanImported,assets:nil,temporaryRoot:root)
        #expect(try CassiniReader.read(contentsOf:cleanLibExport.url).manifest?.raw["x"]?["codemyriad.io"]?["revision"] == .number(ceiling))

        // Repaired file at the ceiling cannot advance and must refuse with newerFormat on both paths.
        let repaired = try namespacedDocument(root:root,kind:.normalizedCreated,revision:ceiling)
        let repairedFile = try CassiniReader.read(contentsOf:repaired)
        #expect(throws:MeetingExportError.newerFormat) {
            _ = try MeetingFileExporter.cassini(MeetingPresentation.external(repairedFile,url:repaired),assets:nil,temporaryRoot:root)
        }
        let repairedImported = try LibraryImport.copy(repaired,into:root.appendingPathComponent("RepairedLib"))
        #expect(throws:MeetingExportError.newerFormat) {
            _ = try MeetingFileExporter.cassini(repairedImported,assets:nil,temporaryRoot:root)
        }
    }

}
