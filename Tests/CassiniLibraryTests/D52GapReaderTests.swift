// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
import CassiniRecording
@testable import CassiniLibrary

/// codex #106: what the writer saves, the Library reads the same way.
struct D52GapReaderTests {
    private func temporary() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("D52Reader-"+UUID().uuidString) }
    /// A browser track with one jump of `jumpMs` after 10 ms of audio, at 48 kHz.
    private func browserSession(_ parent: URL, jumpMs: Double) throws -> RecordingSession {
        let session = try RecordingSession(parent:parent,title:"Call",source:"chromium")
        try session.addTrack(id:"remote",label:"Guest",kind:"remote",sampleRate:48000,channels:1)
        try session.append(id:"remote",pcm:Data(repeating:1,count:960),offsetMs:0)
        try session.append(id:"remote",pcm:Data(repeating:1,count:960),offsetMs:10 + jumpMs)
        try session.finish()
        return session
    }
    private func scanned(_ parent: URL) throws -> LibraryMeeting { try #require(LibraryScanner(root:parent).scan().meetings.first) }
    private func editTrack(_ session: RecordingSession, _ edit: (inout [String:Any]) -> Void) throws {
        let url = session.directory.appendingPathComponent("session.json")
        var root = try #require(JSONSerialization.jsonObject(with:Data(contentsOf:url)) as? [String:Any])
        var tracks = try #require(root["tracks"] as? [[String:Any]]); edit(&tracks[0]); root["tracks"] = tracks
        try JSONSerialization.data(withJSONObject:root).write(to:url)
    }

    @Test func aShortBrowserJumpIsSavedCompletedAndScannedUninterrupted() throws {
        let parent = temporary(); defer { try? FileManager.default.removeItem(at:parent) }
        let session = try browserSession(parent,jumpMs:30)
        let track = try #require(try RecordingLoader.load(directory:session.directory).tracks.first)
        #expect(track.gaps?.map(\.kind) == ["jump"] && track.gapFrames == 1440,"The 30 ms jump is recorded and counted")
        #expect(session.manifest.state == "completed" && session.manifest.problemKind == nil)
        #expect(try scanned(parent).state.interruptedAtMs == nil,"A jump under 1 s does not mark the meeting interrupted")
    }
    @Test func aOneSecondJumpIsScannedInterrupted() throws {
        let parent = temporary(); defer { try? FileManager.default.removeItem(at:parent) }
        _ = try browserSession(parent,jumpMs:1000)
        #expect(try scanned(parent).state.interruptedAtMs != nil)
    }
    @Test func onlyMissingOrNullRangesFallBackToTheCounter() throws {
        for (name,gaps) in [("missing",nil),("null",NSNull()),("malformed","x")] as [(String,Any?)] {
            let parent = temporary(); defer { try? FileManager.default.removeItem(at:parent) }
            let session = try browserSession(parent,jumpMs:30)
            try editTrack(session) { $0["gaps"] = gaps }
            #expect(try scanned(parent).state.interruptedAtMs != nil,"\(name) ranges: any counted gap flags, as for older files")
        }
        let parent = temporary(); defer { try? FileManager.default.removeItem(at:parent) }
        let session = try browserSession(parent,jumpMs:30)
        try editTrack(session) { $0["gaps"] = [Any]() }
        #expect(try scanned(parent).state.interruptedAtMs == nil,"An empty list means no gaps, whatever the counter says")
        let writer = temporary(); defer { try? FileManager.default.removeItem(at:writer) }
        let lost = try RecordingSession(parent:writer,title:"Lost",source:"macos")
        try lost.addTrack(id:"mic",label:"Mic",kind:"microphone",sampleRate:48000,channels:1)
        try lost.appendNative(id:"mic",pcm:Data(repeating:1,count:96000),offsetMs:0)
        try lost.padNative(id:"mic",frames:96000,channels:1,rate:48000,offsetMs:1000)
        try lost.finish()
        #expect(try scanned(writer).state.interruptedAtMs == nil,"Two seconds of writer padding is io, never the gap flag (R70)")
    }
}
