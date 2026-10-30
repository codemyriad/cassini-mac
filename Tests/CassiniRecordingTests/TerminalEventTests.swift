// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
import CassiniKit
@_spi(Testing) @testable import CassiniRecording

@Suite struct TerminalEventTests {
    @Test(arguments:CaptureEndReason.allCases) func stopIsDurableOrderedAndIdempotent(_ reason: CaptureEndReason) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let session = try RecordingSession(parent:root,title:"Generated",source:"macos")
        try session.addTrack(id:"mic",label:"Me",kind:"microphone",sampleRate:8000,channels:1)
        try session.append(id:"mic",pcm:Data(repeating:1,count:8000),offsetMs:250)
        try session.transition(events:[.init(atMs:3000,type:"selection",reason:"user",me:true,others:false)])
        try session.finish(problem:nil,kind:nil,reason:reason,atMs:100)
        let file = session.directory.appendingPathComponent("session.json"), bytes = try Data(contentsOf:file)
        let manifest = try RecordingLoader.load(directory:session.directory)
        #expect(manifest.state == "completed" && manifest.tracks.allSatisfy { $0.ended == true })
        #expect(manifest.events?.last == .init(atMs:3000,type:"end",reason:reason.rawValue))
        try session.finish(problem:"Later failure",kind:"io",reason:.error,atMs:10000)
        #expect(try Data(contentsOf:file) == bytes)
        #expect(throws:(any Error).self) { try session.transition(events:[.init(atMs:4000,type:"selection",reason:"user",me:true,others:true)]) }
    }
    @Test func lastEventSlotIsReservedBeforeAnySourceSideEffect() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let session = try RecordingSession(parent:root,title:"Generated",source:"chromium")
        try session.transition(events:(0..<999).map { .init(atMs:Double($0),type:"selection",reason:"user",me:true,others:true) })
        let file = session.directory.appendingPathComponent("session.json"), bytes = try Data(contentsOf:file)
        let entries = try FileManager.default.contentsOfDirectory(atPath:session.directory.path)
        #expect(throws:(any Error).self) {
            try session.transition(starting:[.init(id:"remote",label:"Remote",kind:"remote",sampleRate:8000,channels:1,sourceTrackId:"wire")],
                events:[.init(atMs:999,type:"othersSource",source:"browser",reason:"restored")])
        }
        #expect(try Data(contentsOf:file) == bytes)
        #expect(try FileManager.default.contentsOfDirectory(atPath:session.directory.path) == entries)
        #expect(throws:(any Error).self) { try session.addTrack(id:"late",label:"Late",kind:"remote",sampleRate:8000,channels:1) }
        #expect(try FileManager.default.contentsOfDirectory(atPath:session.directory.path) == entries)
        try session.finish(problem:nil,kind:nil,reason:.user,atMs:999)
        #expect(session.manifest.events?.count == 1000 && session.manifest.events?.last?.type == "end")
    }
    @Test func anUnpublishedFailedStopCanPersistAnErrorEndOnce() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let session = try RecordingSession(parent:root,title:"Generated",source:"macos")
        var once = true
        session.checkpointObserver = { phase in
            if once && phase == .metadataSynchronized { once = false; throw CocoaError(.fileWriteUnknown) }
        }
        #expect(throws:(any Error).self) { try session.finish(problem:nil,kind:nil,reason:.user,atMs:12) }
        let saved = try RecordingLoader.load(directory:session.directory)
        #expect(saved.state == "interrupted" && saved.problemKind == "io")
        #expect(saved.events?.filter { $0.type == "end" }.count == 1 && saved.events?.last?.reason == "error")
    }
    @Test func nativeProtocolKeepsGapClassificationAndTheKnownTrackBoundary() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let session = try RecordingSession(parent:root,title:"Generated",source:"macos")
        try session.addTrack(id:"mic",label:"Me",kind:"microphone",sampleRate:8000,channels:1)
        try session.append(id:"mic",pcm:Data(repeating:1,count:8000),offsetMs:250)
        let writer: any RecordingSinkWriter = session
        try writer.finish(problem:"A counted gap",kind:"gap")
        #expect(session.manifest.problemKind == "gap")
        #expect(session.manifest.events?.last == .init(atMs:750,type:"end",reason:"user"))
    }
}
