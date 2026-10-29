// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import XCTest
@_spi(Testing) import CassiniRecording

final class SourceTransactionTests: XCTestCase {
    func testRejectedMetadataKeepsOldSelectionFilesAndAppendableWriter() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let session = try RecordingSession(parent:root,title:"Rejected transaction",source:"macos")
        try session.addTrack(id:"old",label:"Old",kind:"system",sampleRate:8000,channels:1)
        try session.appendNative(id:"old",pcm:Data(repeating:1,count:1600),offsetMs:0)
        let metadata = session.directory.appendingPathComponent("session.json")
        let before = try Data(contentsOf:metadata)
        let files = try FileManager.default.contentsOfDirectory(atPath:session.directory.path).sorted()
        session.checkpointObserver = { phase in if phase == .metadataSynchronized { throw CocoaError(.fileWriteUnknown) } }
        XCTAssertThrowsError(try session.transition(starting:[.init(id:"new",label:"New",kind:"microphone",sampleRate:8000,channels:1)],ending:["old"],events:[.init(atMs:100,type:"selection",reason:"user",me:true,others:false)]))
        session.checkpointObserver = nil
        XCTAssertEqual(try Data(contentsOf:metadata),before)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath:session.directory.path).sorted(),files)
        XCTAssertEqual(session.manifest.tracks.count,1)
        XCTAssertNotEqual(session.manifest.tracks[0].ended,true)
        try session.appendNative(id:"old",pcm:Data(repeating:2,count:1600),offsetMs:100)
        XCTAssertEqual(session.manifest.tracks[0].frames,1600)
        try session.finish()
    }
    func testFailureAfterPublicationRetainsTheCommittedState() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let session = try RecordingSession(parent:root,title:"Committed transaction",source:"macos")
        try session.addTrack(id:"old",label:"Old",kind:"system",sampleRate:8000,channels:1)
        try session.appendNative(id:"old",pcm:Data(repeating:1,count:1600),offsetMs:0)
        session.checkpointObserver = { phase in if phase == .metadataPublished { throw CocoaError(.fileWriteUnknown) } }
        XCTAssertThrowsError(try session.transition(starting:[.init(id:"new",label:"New",kind:"microphone",sampleRate:8000,channels:1)],ending:["old"])) { error in
            XCTAssertTrue(error is RecordingTransitionCommittedError)
        }
        session.checkpointObserver = nil
        let loaded = try RecordingLoader.load(directory:session.directory)
        XCTAssertEqual(loaded.tracks.map(\.id),["old","new"])
        XCTAssertEqual(session.manifest.tracks[0].ended,true)
        XCTAssertThrowsError(try session.appendNative(id:"old",pcm:Data(repeating:2,count:160),offsetMs:100))
        try session.appendNative(id:"new",pcm:Data(repeating:3,count:160),offsetMs:100)
        try session.finish(problem:"Injected post-publication failure",kind:"io")
    }
}
