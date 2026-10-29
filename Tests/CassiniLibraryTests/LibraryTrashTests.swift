// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
import Darwin
@testable import CassiniLibrary

final class LibraryTrashTests: XCTestCase {
    func withFolder(_ body: (URL, URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let folder = root.appendingPathComponent("Recording-" + UUID().uuidString.lowercased())
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        try body(root,folder)
    }
    func testUsesReturnedURLAndNeverTouchesOtherFolders() throws {
        try withFolder { root,folder in
            let other = root.appendingPathComponent("other"); try Data([1,2,3]).write(to:other)
            let result = root.appendingPathComponent("private-fake-trash-renamed")
            XCTAssertEqual(try LibraryTrash.move(folder,roots:[root],trash:{ input in
                XCTAssertEqual(input,folder); try FileManager.default.moveItem(at:input,to:result); return result
            }),result)
            XCTAssertFalse(FileManager.default.fileExists(atPath:folder.path))
            XCTAssertEqual(try Data(contentsOf:other),Data([1,2,3]))
        }
    }
    func testMissingFolderIsAlreadyRemoved() throws {
        try withFolder { root,folder in
            try FileManager.default.removeItem(at:folder)
            XCTAssertNil(try LibraryTrash.move(folder,roots:[root],trash:{ _ in XCTFail("must not trash missing item"); return nil }))
        }
    }
    func testFailureLeavesBytesUntouched() throws {
        try withFolder { root,folder in
            let file = folder.appendingPathComponent("meeting.json"); try Data([4,5]).write(to:file)
            XCTAssertThrowsError(try LibraryTrash.move(folder,roots:[root],trash:{ _ in throw CocoaError(.featureUnsupported) })) {
                XCTAssertTrue(LibraryTrash.unsupported($0))
            }
            XCTAssertEqual(try Data(contentsOf:file),Data([4,5]))
        }
    }
    func testRejectsExternalFolderAndSymlink() throws {
        try withFolder { root,folder in
            XCTAssertThrowsError(try LibraryTrash.move(folder,roots:[root.appendingPathComponent("elsewhere")],trash:{ _ in XCTFail(); return nil }))
            let link = root.appendingPathComponent("Received-" + UUID().uuidString.lowercased())
            try FileManager.default.createSymbolicLink(at:link,withDestinationURL:folder)
            XCTAssertThrowsError(try LibraryTrash.move(link,roots:[root],trash:{ _ in XCTFail(); return nil }))
            XCTAssertTrue(FileManager.default.fileExists(atPath:folder.path))
        }
    }
    func testDoesNotTrashWhileMetadataOrSpeechOrImportLockHeld() throws {
        try withFolder { root,folder in
            for path in [root.path,folder.path,folder.appendingPathComponent(".transcription.lock").path] {
                let fd = open(path,O_RDONLY | O_CREAT | O_CLOEXEC,0o600)
                XCTAssertGreaterThanOrEqual(fd,0)
                defer { flock(fd,LOCK_UN); close(fd) }
                XCTAssertEqual(flock(fd,LOCK_EX | LOCK_NB),0)
                XCTAssertThrowsError(try LibraryTrash.move(folder,roots:[root],trash:{ _ in XCTFail("busy item"); return nil }))
                flock(fd,LOCK_UN)
            }
            _ = try LibraryTrash.move(folder,roots:[root],trash:{ _ in nil })
        }
    }
    func testRejectsNonRegularSpeechLockWithoutBlocking() throws {
        try withFolder { root,folder in
            XCTAssertEqual(mkfifo(folder.appendingPathComponent(".transcription.lock").path,0o600),0)
            XCTAssertThrowsError(try LibraryTrash.move(folder,roots:[root],trash:{ _ in XCTFail(); return nil }))
        }
    }
    func testCreatesAndHoldsIdleSpeechLockThroughTrashCall() throws {
        try withFolder { root,folder in
            _ = try LibraryTrash.move(folder,roots:[root],trash:{ _ in
                let contender = open(folder.appendingPathComponent(".transcription.lock").path,O_RDWR | O_CLOEXEC)
                XCTAssertGreaterThanOrEqual(contender,0); defer { close(contender) }
                XCTAssertNotEqual(flock(contender,LOCK_EX | LOCK_NB),0,"No worker can enter during Trash")
                return nil
            })
        }
    }
}
