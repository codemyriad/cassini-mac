// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import CassiniLibrary

struct RecordingNotesTests {
    @Test func insertionAtTheBodyStartKeepsTheExistingNoteTime() {
        var notes = RecordingNotes(lines:[.init(atMs:5123,text:"First")],displayed:"00:00:05  First")
        notes.edit("00:00:05  \nFirst",atMs:600000,prefix:stamp)
        #expect(notes.lines == [.init(atMs:nil,text:""),.init(atMs:5123,text:"First")])
    }
    @Test func pastedLineBeforeAnEditedNoteDoesNotStealItsTimeOrSaveItsPrefix() {
        var notes = RecordingNotes(lines:[.init(atMs:5123,text:"First")],displayed:"00:00:05  First")
        notes.edit("Intro\n00:00:05  First updated",atMs:20000,prefix:stamp)
        #expect(notes.lines == [.init(atMs:20000,text:"Intro"),.init(atMs:5123,text:"First updated")])
    }
    @Test func undoAndRedoRestoreExactMillisecondsWhileRetypingStartsANewNote() {
        var notes = RecordingNotes(lines:[.init(atMs:12345,text:"First"),.init(atMs:33456,text:"Second")],displayed:"00:00:12  First\n00:00:33  Second")
        notes.edit("",atMs:40000,prefix:stamp)
        notes.edit("00:00:12  First\n00:00:33  Second",atMs:45000,restoration:.undo,prefix:stamp)
        #expect(notes.lines == [.init(atMs:12345,text:"First"),.init(atMs:33456,text:"Second")])
        notes.edit("",atMs:50000,restoration:.redo,prefix:stamp)
        #expect(notes.lines == [.init(atMs:nil,text:"")])
        notes.edit("First",atMs:55000,prefix:stamp)
        #expect(notes.lines == [.init(atMs:55000,text:"First")])
    }
    @Test func retypingBeforeBlurKeepsTheOldPrefixOutOfTheNewBody() {
        var notes = RecordingNotes(lines:[.init(atMs:5123,text:"First")],displayed:"00:00:05  First")
        notes.edit("00:00:05  ",atMs:10000,prefix:stamp)
        notes.edit("00:00:05  Again",atMs:23000,prefix:stamp)
        #expect(notes.lines == [.init(atMs:23000,text:"Again")])
    }
    @Test func clearingANoteClearsItsTimeAndRetypingPinsANewTime() {
        var notes = RecordingNotes(lines:[],displayed:"")
        notes.edit("A",atMs:5000,prefix:stamp)
        notes.edit("",atMs:6000,prefix:stamp)
        #expect(notes.lines == [.init(atMs:nil,text:"")])
        notes.reformat("")
        notes.edit("Later",atMs:10000,prefix:stamp)
        #expect(notes.lines == [.init(atMs:10000,text:"Later")])
    }
    @Test func editingThePrefixSpacingDoesNotTurnItIntoNoteContent() {
        let time = LibraryFormat.position(5000)
        var notes = RecordingNotes(lines:[.init(atMs:5000,text:"Hello")],displayed:time + "  Hello")
        notes.edit(time + " Hello",atMs:10000,prefix:stamp)
        #expect(notes.lines == [.init(atMs:5000,text:"Hello")])
        notes.reformat(time + "  Hello")
        notes.edit(time + "  ",atMs:11000,prefix:stamp)
        #expect(notes.lines.first?.atMs == nil && notes.lines.first?.text == "")
    }
    @Test func firstCharacterPinsTheTimeAndEditingKeepsIt() {
        var notes = RecordingNotes(lines:[],displayed:"")
        notes.edit("  ",atMs:1000,prefix:stamp)
        #expect(notes.lines.first?.atMs == nil)
        notes.edit("Decision",atMs:2200,prefix:stamp)
        notes.edit("Decision updated\n",atMs:4000,prefix:stamp)
        #expect(notes.lines.map(\.atMs) == [2200,nil])
        notes.edit("Decision updated\nNext",atMs:5600,prefix:stamp)
        #expect(notes.lines.map(\.atMs) == [2200,5600])
    }
    @Test func insertingAndRemovingLinesKeepsExistingTimes() {
        var notes = RecordingNotes(lines:[.init(atMs:1000,text:"First"),.init(atMs:2000,text:"Last")],displayed:"First\nLast")
        notes.edit("New\nFirst\nLast",atMs:9000,prefix:stamp)
        #expect(notes.lines.map(\.atMs) == [9000,1000,2000])
        notes.edit("New\nFirst\nMiddle\nLast",atMs:10000,prefix:stamp)
        #expect(notes.lines.map(\.atMs) == [9000,1000,10000,2000])
        notes.edit("First\nMiddle\nLast",atMs:11000,prefix:stamp)
        #expect(notes.lines.map(\.atMs) == [1000,10000,2000])
    }
    @Test func formattedPrefixesAreDisplayOnlyAndSplittingCreatesANewNote() {
        var notes = RecordingNotes(lines:[.init(atMs:1000,text:"First last")],displayed:"00:00:01  First last")
        notes.edit("00:00:01  First last!",atMs:9000,prefix:stamp)
        #expect(notes.lines.first == .init(atMs:1000,text:"First last!"))
        notes.edit("00:00:01  First\nlast!",atMs:10000,prefix:stamp)
        #expect(notes.lines == [.init(atMs:1000,text:"First"),.init(atMs:10000,text:"last!")])
    }
    @Test func oversizedMetadataLeavesTheLastReadableFileIntact() throws {
        let f = try Fixture()
        let writer = try MeetingMetadataWriter(directory:f.folder,id:f.id)
        try writer.createIfNeeded()
        let path = f.folder.appendingPathComponent("meeting.json"), original = try Data(contentsOf:path)
        #expect(throws:POSIXError(.EFBIG)) {
            try writer.transaction { meta in
                meta["notes"] = (0..<12).map { ["atMs":$0,"text":String(repeating:"a",count:100000)] as [String:Any] }
            }
        }
        #expect(try Data(contentsOf:path) == original)
        try writer.transaction { $0["title"] = "Still writable"; $0["titleSource"] = "user" }
        #expect(try AppMetadata.parse(Data(contentsOf:path)).title == "Still writable")
    }
    private func stamp(_ atMs: Int64) -> String { LibraryFormat.position(atMs) + "  " }
}
