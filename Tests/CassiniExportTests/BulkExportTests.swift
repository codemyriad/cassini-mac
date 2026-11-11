// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
import CassiniKit
import CassiniLibrary
import CassiniRecording
@testable import CassiniExport

struct BulkExportTests {
    private func root() throws -> URL {
        let url=FileManager.default.temporaryDirectory.appendingPathComponent("BulkExport-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:url,withIntermediateDirectories:true);return url
    }
    private func pair(_ root:URL) throws -> [LibraryMeeting] {
        let source=try #require(Bundle.module.url(forResource:"stereo-tone",withExtension:"opus",subdirectory:"Fixtures"))
        let firstSource=root.appendingPathComponent("First.opus")
        _ = try OpusStreamFile.rewrite(Data(contentsOf:source),tags:PortableMeetingTags.packet(comments:[.init(name:"TITLE",value:"Budget/Review")]),to:firstSource)
        let first=try LibraryImport.copy(firstSource,into:root.appendingPathComponent("Library"))
        let other=root.appendingPathComponent("Other.opus")
        _ = try OpusStreamFile.rewrite(Data(contentsOf:source),tags:PortableMeetingTags.packet(comments:[.init(name:"TITLE",value:"budget/review")]),to:other)
        let second=try LibraryImport.copy(other,into:root.appendingPathComponent("Library"))
        return [first,second]
    }
    @Test(.enabled(if:ProcessInfo.processInfo.environment["CASSINI_OPUS_ASSETS"] != nil))
    func ownCaptureBecomesACompletePortableArchiveEntry() throws {
        let root=try root();defer {try? FileManager.default.removeItem(at:root)}
        let session=try RecordingSession(parent:root.appendingPathComponent("Library"),title:"English capture",source:"macos")
        try session.addTrack(id:"mic",label:"Microphone",kind:"microphone",sampleRate:16000,channels:1)
        try session.appendNative(id:"mic",pcm:Data(repeating:0,count:3200),offsetMs:0);try session.finish()
        try MeetingMetadataWriter(directory:session.directory,id:session.manifest.id).transaction {$0["notes"] = [["atMs":0,"text":"Saved annotation"]]}
        let meeting=try #require(LibraryScanner(root:session.directory.deletingLastPathComponent()).scan().meetings.first)
        let assetsRoot=URL(fileURLWithPath:try #require(ProcessInfo.processInfo.environment["CASSINI_OPUS_ASSETS"]))
        let hashes=try JSONDecoder().decode([String:String].self,from:Data(contentsOf:assetsRoot.appendingPathComponent("unsigned-sha256.json")))
        let expected=try #require(hashes["libopus.0.dylib"])
        let assets=try OpusAssets.builtForTests(directory:assetsRoot,expectedBinarySHA256:expected)
        let artifact=try MeetingArchiveExporter.make([meeting],assets:assets,temporaryRoot:root)
        let archive=try ZIPArchive(url:artifact.url);var bytes=Data()
        #expect(archive.entries.count==1 && archive.entries[0].method==0)
        try archive.read(archive.entries[0],remainingBytes:20_000_000_000) {bytes.append($0)}
        let file=try CassiniReader.read(bytes)
        #expect(file.state == .ok && file.manifest?.meeting.title == "English capture")
        #expect(file.manifest?.raw["meeting"]?["recordedAtUtc"]?.string?.hasSuffix("Z")==true)
        #expect(file.manifest?.raw["x"]?["gocassini.com"]?["notes"]?.array?.first?["text"]?.string == "Saved annotation")
        #expect(try file.audioDigest?.get().channels==1)
    }
    @Test func allAndSelectedKeepOriginalAudioAndUseCollisionSafeNames() throws {
        let root=try root();defer {try? FileManager.default.removeItem(at:root)}
        let meetings=try pair(root)
        let artifact=try MeetingArchiveExporter.make(meetings,assets:nil,temporaryRoot:root)
        let archive=try ZIPArchive(url:artifact.url)
        #expect(archive.entries.map(\.name) == ["Budget-Review.opus","budget-review 2.opus"])
        #expect(archive.entries.allSatisfy {$0.method==0})
        for (entry,meeting) in zip(archive.entries,meetings) {
            var bytes=Data();try archive.read(entry,remainingBytes:20_000_000_000) {bytes.append($0)}
            #expect(bytes == (try Data(contentsOf:meeting.audioFiles[0])))
        }
        let selected=try MeetingArchiveExporter.make([meetings[1]],assets:nil,temporaryRoot:root)
        #expect(try ZIPArchive(url:selected.url).entries.map(\.name) == ["budget-review.opus"])
    }
    @Test func completeDocumentsKeepWordsAndNewNotesWhileOpaqueFilesKeepEveryByte() throws {
        let root=try root();defer {try? FileManager.default.removeItem(at:root)}
        let repository=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source=repository.appendingPathComponent("Tests/CassiniKitTests/Conformance/opus/001-minimal-v1.opus")
        let original=try CassiniReader.read(contentsOf:source)
        let meeting=try LibraryImport.copy(source,into:root.appendingPathComponent("Library"))
        try MeetingMetadataWriter(directory:meeting.folder,id:meeting.id).transaction { $0["notes"] = [["atMs":0,"text":"English annotation"]] }
        let complete=try MeetingArchiveExporter.make([meeting],assets:nil,temporaryRoot:root)
        let archive=try ZIPArchive(url:complete.url)
        var data=Data();try archive.read(archive.entries[0],remainingBytes:20_000_000_000) {data.append($0)}
        let exported=try CassiniReader.read(data)
        #expect(exported.state == .ok)
        #expect(exported.manifest?.meeting.id == original.manifest?.meeting.id)
        #expect(try exported.audioDigest?.get() == original.audioDigest?.get())
        #expect(exported.defaultTranscript?.load.transcript?.items == original.defaultTranscript?.load.transcript?.items)
        #expect(exported.manifest?.raw["x"]?["gocassini.com"]?["notes"]?.array?.first?["text"]?.string == "English annotation")
        var comments=try #require(original.tags?.comments);comments.removeAll {$0.name=="CASSINI_FORMAT"};comments.append(.init(name:"CASSINI_FORMAT",value:"org.cassini.portable-meeting/999"))
        let opaque=root.appendingPathComponent("Opaque.opus")
        _ = try OpusStreamFile.rewrite(Data(contentsOf:source),tags:PortableMeetingTags.packet(comments:comments),to:opaque)
        let imported=try LibraryImport.copy(opaque,into:root.appendingPathComponent("Library"))
        let raw=try MeetingArchiveExporter.make([imported],assets:nil,temporaryRoot:root)
        let rawArchive=try ZIPArchive(url:raw.url);var carried=Data()
        try rawArchive.read(rawArchive.entries[0],remainingBytes:20_000_000_000) {carried.append($0)}
        #expect(carried == (try Data(contentsOf:opaque)))
        try MeetingRename.apply("Opaque local rename",to:imported)
        #expect(throws:MeetingExportError.invalidSource) {try MeetingArchiveExporter.make([imported],assets:nil,temporaryRoot:root)}
    }
    @Test func renamedPlainAudioKeepsItsTitleAndAudioOnAnotherImport() throws {
        let root=try root();defer {try? FileManager.default.removeItem(at:root)}
        let meeting=try #require(pair(root).first)
        let before=try Data(contentsOf:meeting.audioFiles[0])
        try MeetingRename.apply("Renamed locally",to:meeting)
        let artifact=try MeetingArchiveExporter.make([meeting],assets:nil,temporaryRoot:root)
        let archive=try ZIPArchive(url:artifact.url);var bytes=Data()
        try archive.read(archive.entries[0],remainingBytes:20_000_000_000) {bytes.append($0)}
        let file=try CassiniReader.read(bytes)
        #expect(file.state == .ok && file.manifest?.meeting.title == "Renamed locally")
        #expect(try file.audioDigest?.get() == CassiniReader.read(before).audioDigest?.get())
        let portable=root.appendingPathComponent("Transfer.opus");try bytes.write(to:portable)
        let received=try LibraryImport.copy(portable,into:root.appendingPathComponent("Another Library"))
        #expect(received.title == "Renamed locally")
        #expect(try Data(contentsOf:meeting.audioFiles[0]) == before)
    }
    @Test func cancellationAndMissingSelectionMemberRemovePartialArchive() throws {
        let root=try root();defer {try? FileManager.default.removeItem(at:root)}
        let meetings=try pair(root),scratch=root.appendingPathComponent("Scratch")
        try FileManager.default.createDirectory(at:scratch,withIntermediateDirectories:true)
        var cancelled=false
        #expect(throws:CancellationError.self) {try MeetingArchiveExporter.make(meetings,assets:nil,temporaryRoot:scratch,shouldCancel:{cancelled},progress:{if $0.done==1 {cancelled=true}})}
        #expect(try FileManager.default.contentsOfDirectory(atPath:scratch.path).isEmpty)
        try FileManager.default.removeItem(at:meetings[1].folder)
        #expect(throws:MeetingExportError.self) {try MeetingArchiveExporter.make(meetings,assets:nil,temporaryRoot:scratch)}
        #expect(try FileManager.default.contentsOfDirectory(atPath:scratch.path).isEmpty)
    }
    @Test func longUnicodeNamesStayWithinFilesystemAndZipBounds() throws {
        let root=try root();defer {try? FileManager.default.removeItem(at:root)}
        let meeting=try #require(pair(root).first)
        try MeetingMetadataWriter(directory:meeting.folder,id:meeting.id).transaction {$0["title"] = String(repeating:"🛰",count:200)}
        let artifact=try MeetingArchiveExporter.make([meeting],assets:nil,temporaryRoot:root)
        let entry=try #require(ZIPArchive(url:artifact.url).entries.first)
        #expect(entry.name.utf8.count<=255 && entry.name.hasSuffix(".opus"))
    }
}
