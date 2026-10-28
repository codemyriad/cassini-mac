// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Darwin
import XCTest
@testable import CassiniTranscription

final class SpeechScratchTests: XCTestCase {
    func testLeaseKeepsActiveAudioAndCleansStaleAudioEvenWithALiveReusedPID() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:false)
        defer { try? FileManager.default.removeItem(at:root) }
        var active: SpeechScratch? = try SpeechScratch(root:root)
        let activeDirectory = active!.directory
        let payload = Data("Generated private PCM fixture".utf8)
        try payload.write(to:activeDirectory.appendingPathComponent("mono.f32"))
        let stale = root.appendingPathComponent("CassiniSpeech-\(getpid())-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at:stale,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        try Data().write(to:stale.appendingPathComponent(".lease"))
        try payload.write(to:stale.appendingPathComponent("mono.f32"))
        SegmentedAudio.removeAbandonedScratch(in:root)
        XCTAssertFalse(FileManager.default.fileExists(atPath:stale.path))
        XCTAssertEqual(try Data(contentsOf:activeDirectory.appendingPathComponent("mono.f32")),payload)
        active = nil
        XCTAssertFalse(FileManager.default.fileExists(atPath:activeDirectory.path))
    }
    func testCleanupDoesNotFollowAScratchDirectorySymlink() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:false)
        defer { try? FileManager.default.removeItem(at:root) }
        let target = root.appendingPathComponent("keep")
        try FileManager.default.createDirectory(at:target,withIntermediateDirectories:false)
        let audio = target.appendingPathComponent("mono.f32"); try Data([1,2]).write(to:audio)
        try FileManager.default.createSymbolicLink(at:root.appendingPathComponent("CassiniSpeech-\(getpid())-\(UUID().uuidString)"),withDestinationURL:target)
        SegmentedAudio.removeAbandonedScratch(in:root)
        XCTAssertEqual(try Data(contentsOf:audio),Data([1,2]))
    }
}
