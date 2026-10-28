// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import CassiniLibrary

struct RecordingNotesTests {
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
