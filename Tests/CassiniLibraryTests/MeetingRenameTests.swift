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
        try MeetingRename.apply("  Design review\n",to:meeting)
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
    @Test func receivedBlankNameRemovesOverrideAndRestoresFilename() throws {
        let f = try Fixture(), folder = try f.received(plain:true)
        try f.metadata(in:folder,received:["originalName":"Lesson recording.opus","sha256":String(repeating:"a",count:64),"importedAtMs":1793107080000])
        let audioFile = folder.appendingPathComponent("Lesson recording.opus")
        let source = folder.appendingPathComponent("original.opus")
        _ = try OpusStreamFile.rewrite(Data(contentsOf:source),tags:Data("OpusTags".utf8) + Data(repeating:0,count:8),to:audioFile)
        try FileManager.default.removeItem(at:source)
        let audio = try Data(contentsOf:audioFile)
        let meeting = try #require(LibraryScanner(root:f.root).scan().meetings.first)
        try MeetingRename.apply(" \n\t",to:meeting)
        let reopened = try #require(LibraryScanner(root:f.root).scan().meetings.first)
        #expect(reopened.title == "Lesson recording" && reopened.exportTitle == "Lesson recording")
        #expect(reopened.received == meeting.received && reopened.start == meeting.start)
        #expect(try Data(contentsOf:audioFile) == audio)
        let metadata = try JSONParser.parse(Data(contentsOf:folder.appendingPathComponent("meeting.json")))
        #expect(metadata["title"] == .null && metadata["titleSource"]?.string == "meeting-window")
    }
    @Test func blankRecordingNameRestoresCapturedTitleAndPreservesNotes() throws {
        let f = try Fixture()
        try f.editCapture { $0["title"] = "Captured meeting name" }
        try f.metadata { $0["notes"] = [["atMs":10,"text":"Preserved note"]] }
        let meeting = try #require(LibraryScanner(root:f.root).scan().meetings.first)
        let capture = try Data(contentsOf:f.folder.appendingPathComponent("session.json"))
        try MeetingRename.apply(" \n\t",to:meeting)
        let restored = try #require(LibraryScanner(root:f.root).scan().meetings.first)
        #expect(restored.title == "Captured meeting name")
        #expect(restored.notes.first?.text == "Preserved note")
        let metadata = try JSONParser.parse(Data(contentsOf:f.folder.appendingPathComponent("meeting.json")))
        #expect(metadata["title"] == .null && metadata["titleSource"]?.string == "meeting-window")
        #expect(try Data(contentsOf:f.folder.appendingPathComponent("session.json")) == capture)
    }
    @Test func blankWithoutCapturedNameDoesNotStoreTheDisplayFallback() throws {
        let f = try Fixture()
        try f.editCapture { $0.removeValue(forKey:"title") }
        try f.metadata()
        let meeting = try #require(LibraryScanner(root:f.root).scan().meetings.first)
        try MeetingRename.apply("",to:meeting)
        let restored = try #require(LibraryScanner(root:f.root).scan().meetings.first)
        #expect(restored.title == "Untitled meeting")
        let metadata = try JSONParser.parse(Data(contentsOf:f.folder.appendingPathComponent("meeting.json")))
        #expect(metadata["title"] == .null && metadata["titleSource"]?.string == "meeting-window")
    }
    @Test func activeSavingAndReadOnlyMeetingsCannotBeRenamed() throws {
        let f = try Fixture(); try f.metadata()
        let file = f.folder.appendingPathComponent("meeting.json"), before = try Data(contentsOf:f.folder.appendingPathComponent("meeting.json"))
        for phase: CaptureActivity in [.recording,.saving] {
            let meeting = try #require(LibraryScanner(root:f.root,activity:CaptureActivitySnapshot([f.id:phase])).scan().meetings.first)
            #expect(throws:(any Error).self) { try MeetingRename.apply("New",to:meeting) }
        }
        var meeting = try #require(LibraryScanner(root:f.root).scan().meetings.first); meeting.metadataReadOnly = true
        #expect(throws:(any Error).self) { try MeetingRename.apply("New",to:meeting) }
        #expect(try Data(contentsOf:file) == before)
    }
    @Test func unchangedTitleDoesNotWriteAndLongNamesRespectScalarLimit() throws {
        let f = try Fixture(); try f.metadata()
        let file = f.folder.appendingPathComponent("meeting.json"), before = try Data(contentsOf:f.folder.appendingPathComponent("meeting.json"))
        let meeting = try #require(LibraryScanner(root:f.root).scan().meetings.first)
        try MeetingRename.apply("  Renamed  ",to:meeting)
        #expect(try Data(contentsOf:file) == before)
        try MeetingRename.apply(String(repeating:"😀",count:501),to:meeting)
        #expect(try LibraryScanner(root:f.root).scan().meetings.first?.title?.unicodeScalars.count == 500)
    }
}
