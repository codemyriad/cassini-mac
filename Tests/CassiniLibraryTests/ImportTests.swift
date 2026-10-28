// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import CryptoKit
import Testing
@testable import CassiniLibrary

struct LibraryImportTests {
    @Test(arguments:[true,false]) func privateCopyKeepsOriginalAndEmbeddedTranscript(plain: Bool) throws {
        let f = try Fixture(), downloads = f.root.appendingPathComponent("Downloads"), library = f.root.appendingPathComponent("Library")
        try FileManager.default.createDirectory(at:downloads,withIntermediateDirectories:true)
        let source = downloads.appendingPathComponent("Meeting.opus")
        let fixture = f.repository.appendingPathComponent("Tests/CassiniKitTests/Conformance/opus/\(plain ? "002-plain-audio" : "001-minimal-v1").opus")
        try FileManager.default.copyItem(at:fixture,to:source)
        let original = try Data(contentsOf:source)
        let meeting = try LibraryImport.copy(source,into:library)
        #expect(meeting.state.origin == .received && meeting.state.lifecycle == .saved)
        #expect(meeting.state.transcript == (plain ? .none : .done))
        #expect(meeting.canWriteDown == plain)
        #expect(meeting.received?.originalFolderName == "Downloads")
        #expect(meeting.received?.sha256 == SHA256.hash(data:original).map { String(format:"%02x",$0) }.joined())
        #expect(try Data(contentsOf:source) == original)
        let copied = try #require(meeting.audioFiles.first)
        #expect(try Data(contentsOf:copied) == original)
        #expect((try FileManager.default.attributesOfItem(atPath:meeting.folder.path)[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        for file in [copied,meeting.folder.appendingPathComponent("meeting.json")] {
            #expect((try FileManager.default.attributesOfItem(atPath:file.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        }
        try FileManager.default.removeItem(at:source)
        #expect(try Data(contentsOf:copied) == original)
        #expect(try LibraryScanner(root:library).scan().meetings.first?.state.audioAvailable == true)
        #expect(plain || !meeting.transcriptItems.isEmpty)
    }
    @Test func duplicateBytesSelectTheExistingMeetingAndKeepEdits() throws {
        let f = try Fixture(), library = f.root.appendingPathComponent("Library")
        let source = f.repository.appendingPathComponent("Tests/CassiniKitTests/Conformance/opus/001-minimal-v1.opus")
        let first = try LibraryImport.copy(source,into:library)
        try MeetingMetadataWriter(directory:first.folder,id:first.id).transaction {
            $0["title"] = "Renamed by the person"; $0["titleSource"] = "user"
            $0["notes"] = [["atMs":120,"text":"A note to keep"]]
        }
        let renamed = f.root.appendingPathComponent("Another name.opus")
        try FileManager.default.copyItem(at:source,to:renamed)
        let second = try LibraryImport.copy(renamed,into:library)
        #expect(second.folder == first.folder && second.id == first.id)
        #expect(second.title == "Renamed by the person" && second.notes.first?.text == "A note to keep")
        #expect(try FileManager.default.contentsOfDirectory(atPath:library.path).filter { $0.hasPrefix("Received-") }.count == 1)
    }
    @Test func invalidLinkedAndCancelledImportsPublishNothing() throws {
        let f = try Fixture(), library = f.root.appendingPathComponent("Library")
        try FileManager.default.createDirectory(at:library,withIntermediateDirectories:true)
        let source = f.repository.appendingPathComponent("Tests/CassiniKitTests/Conformance/opus/002-plain-audio.opus")
        #expect(throws:CancellationError.self) { try LibraryImport.copy(source,into:library,shouldCancel:{ true }) }
        let link = f.root.appendingPathComponent("Linked.opus")
        try FileManager.default.createSymbolicLink(at:link,withDestinationURL:source)
        #expect(throws:(any Error).self) { try LibraryImport.copy(link,into:library) }
        let invalid = f.root.appendingPathComponent("Invalid.opus"); try Data("invalid".utf8).write(to:invalid)
        #expect(throws:(any Error).self) { try LibraryImport.copy(invalid,into:library) }
        #expect(try FileManager.default.contentsOfDirectory(atPath:library.path).isEmpty)
    }
}
