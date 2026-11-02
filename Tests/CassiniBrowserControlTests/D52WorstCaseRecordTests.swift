// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
import CassiniKit
import CassiniLibrary
import CassiniRecording
@testable import CassiniBrowserControl

/// codex #106: the supported worst case, 64 tracks each with 1000 D52.2 ranges and
/// the overflow marker at large session offsets, survives every reader and writer:
/// session.json readers, the capture record in meeting.json, and Library moves.
struct D52WorstCaseRecordTests {
    @Test func theSupportedWorstCaseRoundTripsThroughEveryReaderAndWriter() throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("D52Worst-"+UUID().uuidString)
        let moved = FileManager.default.temporaryDirectory.appendingPathComponent("D52WorstMoved-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:parent); try? FileManager.default.removeItem(at:moved) }
        let session = try RecordingSession(parent:parent,title:String(repeating:"𝄞",count:200),source:"macos")
        let rate = 44100.0, start = 86_000_000.123456789
        for t in 0..<64 {
            try session.addTrack(id:"t\(t)-"+String(repeating:"x",count:120),label:String(repeating:"𝄞",count:200),kind:"microphone",sampleRate:Int(rate),channels:1)
        }
        for track in session.manifest.tracks {
            for k in 0...1001 { try session.appendNative(id:track.id,pcm:Data(count:2),offsetMs:start + Double(2*k)*1000/rate) }
        }
        try session.finish()
        func fullRanges(_ count: Int?, _ last: String?) -> Bool { count == 1001 && last == "overflow" }

        // session.json, with room for the rest of the worst case: 11-digit frame
        // counts and longer kinds on every range, 999 events and a source row per track.
        let sessionBytes = try Data(contentsOf:session.directory.appendingPathComponent("session.json")).count
        let rest = 64*1001*16 + 999*256 + 64*1024
        #expect(sessionBytes > 1_048_576 && sessionBytes + rest <= SessionManifestLimit.bytes,"\(sessionBytes) bytes")
        let loaded = try RecordingLoader.load(directory:session.directory)
        #expect(loaded.tracks.count == 64 && loaded.state == "completed")
        #expect(loaded.tracks.allSatisfy { fullRanges($0.gaps?.count,$0.gaps?.last?.kind) && $0.startOffsetMs == start })

        // The capture record in meeting.json carries every range and reads back whole.
        let metadata = try MeetingMetadataWriter(directory:session.directory,id:session.manifest.id)
        try metadata.createIfNeeded()
        try CaptureRecordWriter.write(loaded,directory:session.directory)
        let meetingBytes = try Data(contentsOf:session.directory.appendingPathComponent("meeting.json")).count
        #expect(meetingBytes > 1_048_576 && meetingBytes <= MeetingMetadataLimit.bytes,"\(meetingBytes) bytes")
        let inputs = RecordingDetailsReport.Inputs.load(folder:session.directory,lifecycle:.saved,title:"Worst",transcriptDone:false)
        let tracks = try #require(inputs.captureRecord?["tracks"]?.array)
        #expect(tracks.count == 64 && tracks.allSatisfy { fullRanges($0["gaps"]?.array?.count,$0["gaps"]?.array?.last?["kind"]?.string) })
        #expect(inputs.session?["tracks"]?.array?.count == 64,"Details reads the large session.json too")
        try metadata.transaction { $0["title"] = "Edited after the record" }   // a later edit keeps the record
        let edited = RecordingDetailsReport.Inputs.load(folder:session.directory,lifecycle:.saved,title:"Worst",transcriptDone:false)
        #expect(edited.captureRecord?["tracks"]?.array?.count == 64)

        // The Library scans it as a saved, uninterrupted meeting with its metadata.
        let meeting = try #require(try LibraryScanner(root:parent).scan().meetings.first)
        #expect(meeting.title == "Edited after the record" && meeting.state.interruptedAtMs == nil)
        #expect(meeting.audioTracks.count == 64 && meeting.audioTracks.allSatisfy { $0.gaps?.count == 1001 && abs(($0.startOffsetMs ?? 0) - start) < 0.001 })

        // And it is eligible to move, and moves.
        #expect(try LibraryMove.activeOrUnreadable(in:parent).isEmpty,"A large saved recording is not held back as unreadable")
        try FileManager.default.createDirectory(at:moved,withIntermediateDirectories:true)
        let result = try LibraryMove.meetings(from:parent,to:moved)
        #expect(result.moved == [session.directory.lastPathComponent] && result.failed.isEmpty)
    }
}
