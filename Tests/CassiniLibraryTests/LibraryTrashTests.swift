// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
import Darwin
@testable import CassiniLibrary

final class LibraryTrashTests: XCTestCase {
    func withFolder(_ body: (URL, URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let folder = root.appendingPathComponent("Recording-" + UUID().uuidString.lowercased())
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root, folder)
    }

    func testUsesInAppRecentlyDeletedAndNeverTouchesOtherFolders() throws {
        try withFolder { root, folder in
            let other = root.appendingPathComponent("other")
            try Data([1, 2, 3]).write(to: other)
            let meetingJSON = folder.appendingPathComponent("meeting.json")
            try Data("{\"version\":1}".utf8).write(to: meetingJSON)

            let movedURL = try XCTUnwrap(LibraryTrash.move(folder, roots: [root]))
            XCTAssertTrue(movedURL.path.contains("/.cassini/trash/"))
            XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
            XCTAssertEqual(try Data(contentsOf: movedURL.appendingPathComponent("meeting.json")), Data("{\"version\":1}".utf8))
            XCTAssertEqual(try Data(contentsOf: other), Data([1, 2, 3]))

            // Scanner ignores .cassini/trash/ completely.
            XCTAssertTrue(try LibraryScanner(root: root).scan().meetings.isEmpty)

            // Listed in Recently Deleted and restorable cleanly.
            let entries = try LibraryTrash.entries(in: root)
            XCTAssertEqual(entries.count, 1)
            try LibraryTrash.restore(entryId: entries[0].entryId, in: root)
            XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("meeting.json").path))
            XCTAssertTrue(try LibraryTrash.entries(in: root).isEmpty)
        }
    }

    func testMissingFolderIsAlreadyRemoved() throws {
        try withFolder { root, folder in
            try FileManager.default.removeItem(at: folder)
            XCTAssertNil(try LibraryTrash.move(folder, roots: [root], trash: { _ in
                XCTFail("must not trash missing item")
                return nil
            }))
        }
    }

    func testFailureLeavesBytesUntouched() throws {
        try withFolder { root, folder in
            let file = folder.appendingPathComponent("meeting.json")
            try Data([4, 5]).write(to: file)
            XCTAssertThrowsError(try LibraryTrash.trashFolder(
                folder,
                roots: [root],
                title: "Weekly",
                recordedAt: nil,
                durationMs: nil,
                injectBeforeMove: { throw POSIXError(.EIO) }
            ))
            XCTAssertEqual(try Data(contentsOf: file), Data([4, 5]))
            XCTAssertTrue(try LibraryTrash.entries(in: root).isEmpty)
        }
    }

    func testRejectsExternalFolderAndSymlink() throws {
        try withFolder { root, folder in
            XCTAssertThrowsError(try LibraryTrash.move(folder, roots: [root.appendingPathComponent("elsewhere")], trash: { _ in
                XCTFail()
                return nil
            }))
            let link = root.appendingPathComponent("Received-" + UUID().uuidString.lowercased())
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: folder)
            XCTAssertThrowsError(try LibraryTrash.move(link, roots: [root], trash: { _ in
                XCTFail()
                return nil
            }))
            XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path))
        }
    }

    func testDoesNotTrashWhileMetadataOrSpeechOrImportLockHeld() throws {
        try withFolder { root, folder in
            for path in [root.path, folder.path, folder.appendingPathComponent(".transcription.lock").path] {
                let fd = open(path, O_RDONLY | O_CREAT | O_CLOEXEC, 0o600)
                XCTAssertGreaterThanOrEqual(fd, 0)
                defer { flock(fd, LOCK_UN); close(fd) }
                XCTAssertEqual(flock(fd, LOCK_EX | LOCK_NB), 0)
                XCTAssertThrowsError(try LibraryTrash.move(folder, roots: [root], trash: { _ in
                    XCTFail("busy item")
                    return nil
                }))
                flock(fd, LOCK_UN)
            }
            _ = try LibraryTrash.move(folder, roots: [root], trash: { _ in nil })
        }
    }

    func testRejectsNonRegularSpeechLockWithoutBlocking() throws {
        try withFolder { root, folder in
            XCTAssertEqual(mkfifo(folder.appendingPathComponent(".transcription.lock").path, 0o600), 0)
            XCTAssertThrowsError(try LibraryTrash.move(folder, roots: [root], trash: { _ in
                XCTFail()
                return nil
            }))
            XCTAssertThrowsError(try LibraryTrash.trashFolder(
                folder,
                roots: [root],
                title: "Test",
                recordedAt: nil,
                durationMs: nil
            ))
        }
    }

    func testCreatesAndHoldsIdleSpeechLockThroughTrashCall() throws {
        try withFolder { root, folder in
            _ = try LibraryTrash.move(folder, roots: [root], trash: { _ in
                let contender = open(folder.appendingPathComponent(".transcription.lock").path, O_RDWR | O_CLOEXEC)
                XCTAssertGreaterThanOrEqual(contender, 0)
                defer { close(contender) }
                XCTAssertNotEqual(flock(contender, LOCK_EX | LOCK_NB), 0, "No worker can enter during Trash")
                return nil
            })
        }
    }

    func testPurgeExpiredRemovesOnlyExpiredEntries() throws {
        try withFolder { root, folder1 in
            let folder2 = root.appendingPathComponent("Received-" + UUID().uuidString.lowercased())
            try FileManager.default.createDirectory(at: folder2, withIntermediateDirectories: true)

            let oldDate = Date(timeIntervalSince1970: 1_794_648_600)
            let recentDate = oldDate.addingTimeInterval(20 * 86_400)
            let checkNow = oldDate.addingTimeInterval(30 * 86_400)

            let e1 = try XCTUnwrap(LibraryTrash.trashFolder(
                folder1, roots: [root], title: "Expired", recordedAt: oldDate, durationMs: 1000, now: oldDate
            ))
            let e2 = try XCTUnwrap(LibraryTrash.trashFolder(
                folder2, roots: [root], title: "Still recent", recordedAt: recentDate, durationMs: 2000, now: recentDate
            ))

            let purged = try LibraryTrash.purgeExpired(in: root, now: checkNow)
            XCTAssertEqual(purged, [e1.entryId])
            let remaining = try LibraryTrash.entries(in: root)
            XCTAssertEqual(remaining.map(\.entryId), [e2.entryId])
        }
    }

    func testRecoverRebuildsMissingEntryJSONAndPreservesUnknownFields() throws {
        try withFolder { root, folder in
            let entry = try XCTUnwrap(LibraryTrash.trashFolder(
                folder,
                roots: [root],
                title: "Rebuild check",
                recordedAt: Date(timeIntervalSince1970: 1_793_379_720),
                durationMs: 60_000,
                now: Date(timeIntervalSince1970: 1_794_648_600)
            ))
            let entryURL = root
                .appendingPathComponent(LibraryTrash.trashDirectory)
                .appendingPathComponent(entry.entryId)
                .appendingPathComponent(LibraryTrash.entryFileName)

            // Inject an unknown field in entry.json and verify entries(in:) tolerates & preserves it on disk.
            var dict = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: entryURL)) as? [String: Any])
            dict["futureUnknownField"] = ["keep": true]
            try JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]).write(to: entryURL)
            XCTAssertEqual(try LibraryTrash.entries(in: root).first?.display.title, "Rebuild check")
            let roundTripped = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: entryURL)) as? [String: Any])
            XCTAssertEqual((roundTripped["futureUnknownField"] as? [String: Bool])?["keep"], true)

            // Remove entry.json without a pending journal; recover rebuilds entry.json dated at discovery.
            try FileManager.default.removeItem(at: entryURL)
            XCTAssertTrue(try LibraryTrash.entries(in: root).isEmpty)

            let discovery = Date(timeIntervalSince1970: 1_795_000_000)
            let report = try LibraryTrash.recover(in: root, now: discovery)
            XCTAssertEqual(report, ["rebuilt \(entry.entryId)"])
            let rebuilt = try XCTUnwrap(LibraryTrash.entries(in: root).first)
            XCTAssertEqual(rebuilt.entryId, entry.entryId)
            XCTAssertEqual(rebuilt.deletedAtUtc, LibraryTrash.formatUTC(discovery))
            XCTAssertEqual(rebuilt.identity, .session(folder.lastPathComponent))
        }
    }
}
