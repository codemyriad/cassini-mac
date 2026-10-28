// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Darwin
import Testing
@testable import CassiniLibrary

struct LibraryMoveTests {
    @Test(arguments:[false,true]) func completeFolderPublicationRetainsBytesAndDefersTheLiveMeeting(copy: Bool) throws {
        let fixture = try Fixture(), output = fixture.root.appendingPathComponent("../Moved-" + UUID().uuidString).standardizedFileURL
        defer { try? FileManager.default.removeItem(at:output) }
        let before = try Dictionary(uniqueKeysWithValues:FileManager.default.contentsOfDirectory(atPath:fixture.folder.path).map { ($0,try Data(contentsOf:fixture.folder.appendingPathComponent($0))) })
        let deferred = "Recording-00000000-0000-4000-8000-000000000001"
        try FileManager.default.createDirectory(at:fixture.root.appendingPathComponent(deferred),withIntermediateDirectories:false)
        let report = try LibraryMove.perform(from:fixture.root,to:output,excluding:[deferred],copyOnly:copy,shouldCancel:{ false })
        #expect(report.moved == [fixture.folder.lastPathComponent] && report.deferred == [deferred] && report.failed.isEmpty)
        #expect(try Dictionary(uniqueKeysWithValues:FileManager.default.contentsOfDirectory(atPath:output.appendingPathComponent(fixture.folder.lastPathComponent).path).map { ($0,try Data(contentsOf:output.appendingPathComponent(fixture.folder.lastPathComponent).appendingPathComponent($0))) }) == before)
        #expect(!FileManager.default.fileExists(atPath:fixture.folder.path))
        #expect(FileManager.default.fileExists(atPath:fixture.root.appendingPathComponent(deferred).path))
    }
    @Test func equalSizeCorruptionIsRejectedBeforeOriginalDeletion() throws {
        let fixture = try Fixture(), output = fixture.root.appendingPathComponent("../Moved-" + UUID().uuidString).standardizedFileURL
        defer { try? FileManager.default.removeItem(at:output) }
        let original = try Data(contentsOf:fixture.folder.appendingPathComponent("session.json"))
        let report = try LibraryMove.perform(from:fixture.root,to:output,excluding:[],copyOnly:true,shouldCancel:{ false },afterCopy:{ stage in
            let file = stage.appendingPathComponent("session.json")
            var bytes = try Data(contentsOf:file); bytes[0] ^= 1; try bytes.write(to:file)
        })
        #expect(report.failed == [fixture.folder.lastPathComponent] && report.moved.isEmpty)
        #expect(try Data(contentsOf:fixture.folder.appendingPathComponent("session.json")) == original)
        #expect(try FileManager.default.contentsOfDirectory(atPath:output.path).isEmpty)
    }
    @Test func inferenceLockDefersWithoutChangingItsPaths() throws {
        let fixture = try Fixture(), output = fixture.root.appendingPathComponent("../Moved-" + UUID().uuidString).standardizedFileURL
        defer { try? FileManager.default.removeItem(at:output) }
        let lock = fixture.folder.appendingPathComponent(".transcription.lock")
        let fd = open(lock.path,O_RDWR | O_CREAT | O_CLOEXEC,0o600); #expect(fd >= 0); defer { close(fd) }
        #expect(flock(fd,LOCK_EX | LOCK_NB) == 0)
        #expect(try LibraryMove.activeOrUnreadable(in:fixture.root) == [fixture.folder.lastPathComponent])
        let report = try LibraryMove.meetings(from:fixture.root,to:output)
        #expect(report.deferred == [fixture.folder.lastPathComponent] && report.moved.isEmpty)
        #expect(FileManager.default.fileExists(atPath:fixture.folder.appendingPathComponent("session.json").path))
        flock(fd,LOCK_UN)
        let done = try LibraryMove.meetings(from:fixture.root,to:output)
        #expect(done.moved == [fixture.folder.lastPathComponent])
    }
    @Test func conflictsAndCancellationKeepOriginalsAndDoNotOverwrite() throws {
        let fixture = try Fixture(), output = fixture.root.appendingPathComponent("../Moved-" + UUID().uuidString).standardizedFileURL
        defer { try? FileManager.default.removeItem(at:output) }
        let existing = output.appendingPathComponent(fixture.folder.lastPathComponent)
        try FileManager.default.createDirectory(at:existing,withIntermediateDirectories:true)
        try Data("keep".utf8).write(to:existing.appendingPathComponent("mine"))
        let report = try LibraryMove.meetings(from:fixture.root,to:output)
        #expect(report.failed == [fixture.folder.lastPathComponent] && report.moved.isEmpty)
        #expect(try Data(contentsOf:existing.appendingPathComponent("mine")) == Data("keep".utf8))
        #expect(FileManager.default.fileExists(atPath:fixture.folder.appendingPathComponent("session.json").path))
        #expect(throws:CancellationError.self) { try LibraryMove.meetings(from:fixture.root,to:output,shouldCancel:{ true }) }
        #expect(throws:(any Error).self) { try LibraryMove.meetings(from:fixture.root,to:fixture.folder) }
    }
    @Test func interruptedCopyAndUnsafeFilesLeaveTheWholeOriginal() throws {
        let fixture = try Fixture(), output = fixture.root.appendingPathComponent("../Moved-" + UUID().uuidString).standardizedFileURL
        defer { try? FileManager.default.removeItem(at:output) }
        let original = try Data(contentsOf:fixture.folder.appendingPathComponent("session.json"))
        var copied = false
        #expect(throws:CancellationError.self) {
            try LibraryMove.perform(from:fixture.root,to:output,excluding:[],copyOnly:true,shouldCancel:{ copied },afterCopy:{ _ in copied = true })
        }
        #expect(copied)
        #expect(try FileManager.default.contentsOfDirectory(atPath:output.path).isEmpty)
        #expect(try Data(contentsOf:fixture.folder.appendingPathComponent("session.json")) == original)
        try FileManager.default.createSymbolicLink(at:fixture.folder.appendingPathComponent("unsafe"),withDestinationURL:fixture.root)
        let report = try LibraryMove.perform(from:fixture.root,to:output,excluding:[],copyOnly:true,shouldCancel:{ false })
        #expect(report.failed == [fixture.folder.lastPathComponent])
        #expect(try FileManager.default.contentsOfDirectory(atPath:output.path).isEmpty)
        #expect(try Data(contentsOf:fixture.folder.appendingPathComponent("session.json")) == original)
    }
}
