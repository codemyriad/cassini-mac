// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
import CassiniKit
@testable import CassiniLibrary

@Suite struct MeetingRenameTests {
    @Test func recordingRenameWhileTranscribingPreservesOtherMetadataAndCapture() throws {
        let f = try Fixture()
        try f.metadata { value in
            value["notes"] = [["atMs":15,"text":" Keep this note\nexactly. "]]
            value["transcript"] = ["status":"running","reference":NSNull()]
            value["future"] = ["unchanged":true]
        }
        let before = try Data(contentsOf:f.folder.appendingPathComponent("meeting.json"))
        let session = try Data(contentsOf:f.folder.appendingPathComponent("session.json"))
        let meeting = try #require(LibraryScanner(root:f.root).scan().meetings.first)
        let audio = try meeting.audioFiles.map { try Data(contentsOf:$0) }
        #expect(try MeetingRename.apply("  Design review\n",to:meeting,untitled:"Untitled meeting") == "Design review")
        let saved = try #require(LibraryScanner(root:f.root).scan().meetings.first)
        #expect(saved.title == "Design review" && saved.state.transcript == .running)
        let after = try JSONParser.parse(Data(contentsOf:f.folder.appendingPathComponent("meeting.json")))
        let old = try JSONSerialization.jsonObject(with:before) as! [String:Any]
        let current = try JSONSerialization.jsonObject(with:Data(contentsOf:f.folder.appendingPathComponent("meeting.json"))) as! [String:Any]
        #expect(after["titleSource"]?.string == "user" && after["revision"]?.int == 1)
        for name in ["notes","speakers","transcript","received","error","future"] { #expect(NSArray(array:[current[name] ?? NSNull()]).isEqual(to:[old[name] ?? NSNull()])) }
        #expect(try Data(contentsOf:f.folder.appendingPathComponent("session.json")) == session)
        #expect(try saved.audioFiles.map { try Data(contentsOf:$0) } == audio)
        #expect(saved.folder == meeting.folder && saved.start == meeting.start)
    }
    @Test func receivedBlankNameIsExplicitUntitledAndDoesNotRestoreFilename() throws {
        let f = try Fixture(), folder = try f.received(plain:true)
        try f.metadata(in:folder,received:["originalName":"Lesson recording.opus","sha256":String(repeating:"a",count:64),"importedAtMs":1793107080000])
        let audio = try Data(contentsOf:folder.appendingPathComponent("original.opus"))
        let meeting = try #require(LibraryScanner(root:f.root).scan().meetings.first)
        _ = try MeetingRename.apply(" \n\t",to:meeting,untitled:"Untitled meeting")
        let reopened = try #require(LibraryScanner(root:f.root).scan().meetings.first)
        #expect(reopened.title == "Untitled meeting" && reopened.exportTitle == "Untitled meeting")
        #expect(reopened.received == meeting.received && reopened.start == meeting.start)
        #expect(try Data(contentsOf:folder.appendingPathComponent("original.opus")) == audio)
        let metadata = try JSONParser.parse(Data(contentsOf:folder.appendingPathComponent("meeting.json")))
        #expect(metadata["title"]?.string == "Untitled meeting" && metadata["titleSource"]?.string == "user")
    }
    @Test func activeSavingAndReadOnlyMeetingsCannotBeRenamed() throws {
        let f = try Fixture(); try f.metadata()
        let file = f.folder.appendingPathComponent("meeting.json"), before = try Data(contentsOf:f.folder.appendingPathComponent("meeting.json"))
        for phase: CaptureActivity in [.recording,.saving] {
            let meeting = try #require(LibraryScanner(root:f.root,activity:CaptureActivitySnapshot([f.id:phase])).scan().meetings.first)
            #expect(throws:(any Error).self) { try MeetingRename.apply("New",to:meeting,untitled:"Untitled meeting") }
        }
        var meeting = try #require(LibraryScanner(root:f.root).scan().meetings.first); meeting.metadataReadOnly = true
        #expect(throws:(any Error).self) { try MeetingRename.apply("New",to:meeting,untitled:"Untitled meeting") }
        #expect(try Data(contentsOf:file) == before)
    }
    @Test func unchangedTitleDoesNotWriteAndLongNamesRespectScalarLimit() throws {
        let f = try Fixture(); try f.metadata()
        let file = f.folder.appendingPathComponent("meeting.json"), before = try Data(contentsOf:f.folder.appendingPathComponent("meeting.json"))
        let meeting = try #require(LibraryScanner(root:f.root).scan().meetings.first)
        _ = try MeetingRename.apply("  Renamed  ",to:meeting,untitled:"Untitled meeting")
        #expect(try Data(contentsOf:file) == before)
        let title = try MeetingRename.apply(String(repeating:"😀",count:501),to:meeting,untitled:"Untitled meeting")
        #expect(title.unicodeScalars.count == 500)
        #expect(try LibraryScanner(root:f.root).scan().meetings.first?.title == title)
    }
}
