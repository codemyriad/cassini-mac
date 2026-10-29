// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Darwin
import Testing
@testable import CassiniLibrary

struct LibraryLocationTests {
    @Test func recordingAccessRejectsMissingRelocatedRootWithoutRecreatingIt() throws {
        let fixture = try Fixture(), config = fixture.root.appendingPathComponent("AppData/location.json")
        let destination = fixture.root.appendingPathComponent("Offline/Library")
        try LibraryLocation(primary:destination).write(file:config)
        #expect(throws:(any Error).self) { try LibraryRouting.withRecordingAccess(file:config,defaultRoot:fixture.root) { _,_ in Issue.record("Missing destination must not be admitted") } }
        #expect(!FileManager.default.fileExists(atPath:destination.deletingLastPathComponent().path))
    }
    @Test func recordingAccessFollowsRenamedBookmarkAndFailsDuringMovePublication() throws {
        let fixture = try Fixture(), config = fixture.root.appendingPathComponent("AppData/location.json")
        let old = fixture.root.appendingPathComponent("Old"), moved = fixture.root.appendingPathComponent("Renamed")
        try FileManager.default.createDirectory(at:old,withIntermediateDirectories:false)
        let bookmark = try old.bookmarkData(options:.withSecurityScope,includingResourceValuesForKeys:nil,relativeTo:nil)
        try LibraryLocation(primary:old,bookmarks:[old.path:bookmark]).write(file:config)
        try FileManager.default.moveItem(at:old,to:moved)
        try LibraryRouting.withRecordingAccess(file:config,defaultRoot:fixture.root) { destination,lease in
            #expect(destination.resolvingSymlinksInPath().path == moved.resolvingSymlinksInPath().path)
            #expect(lease.roots.first == destination)
            #expect(!FileManager.default.fileExists(atPath:old.path))
        }
        try LibraryRouting.withLock(file:config,exclusive:true) {
            #expect(throws:(any Error).self) { try LibraryRouting.withRecordingAccess(file:config,defaultRoot:fixture.root) { _,_ in Issue.record("Move publication must block creation") } }
        }
    }
    @Test func firstRunRecordingAccessAllowsOnlyTheUnconfiguredDefaultToBeCreated() throws {
        let fixture = try Fixture(), config = fixture.root.appendingPathComponent("AppData/location.json")
        let first = fixture.root.appendingPathComponent("NewDefault")
        try LibraryRouting.withRecordingAccess(file:config,defaultRoot:first) { destination,_ in
            #expect(destination.resolvingSymlinksInPath().path == first.resolvingSymlinksInPath().path)
            #expect(!FileManager.default.fileExists(atPath:destination.path))
        }
        #expect(!FileManager.default.fileExists(atPath:first.path))
    }
    @Test func appAndHostReadTheSamePrivateLocationAndRetainFailedRoots() throws {
        let fixture = try Fixture(), config = fixture.root.appendingPathComponent("AppData/location.json")
        let original = try LibraryLocation.read(file:config,defaultRoot:fixture.root)
        #expect(original.primary.path == fixture.root.path && !FileManager.default.fileExists(atPath:config.path))
        let chosen = fixture.root.appendingPathComponent("Elsewhere")
        let updated = LibraryLocation(primary:chosen,previous:[fixture.root,fixture.root],bookmarks:[:])
        try updated.write(file:config)
        #expect(try LibraryLocation.read(file:config) == updated)
        #expect(updated.previousPaths == [fixture.root.path])
        var info = stat(); #expect(lstat(config.path,&info) == 0 && info.st_mode & 0o777 == 0o600)
        let access = try LibraryAccess(updated)
        #expect(access.roots.map { $0.resolvingSymlinksInPath().path } == [chosen,fixture.root].map { $0.resolvingSymlinksInPath().path })
        // A broken pointer must fail closed, never silently create a second
        // Library under the old default path.
        try Data("broken".utf8).write(to:config)
        #expect(throws:(any Error).self) { try LibraryLocation.read(file:config,defaultRoot:fixture.root) }
    }
    @Test func pendingAndFailedMovesSurviveRelaunchWithoutConfusingRetrySelection() throws {
        let fixture = try Fixture(), config = fixture.root.appendingPathComponent("AppData/location.json")
        let old = fixture.root.appendingPathComponent("Old"), new = fixture.root.appendingPathComponent("New")
        let pending = LibraryPendingMove(source:old,folderName:"Recording-00000000-0000-4000-8000-000000000001")
        let failed = LibraryPendingMove(source:old,folderName:"Received-00000000-0000-4000-8000-000000000002",phase:.failed)
        let value = LibraryLocation(primary:new,previous:[old],pendingMoves:[pending,failed])
        try value.write(file:config)
        let reloaded = try LibraryLocation.read(file:config)
        #expect(reloaded.pendingMoves.filter { $0.phase == .pending } == [pending])
        #expect(reloaded.pendingMoves.filter { $0.phase == .failed } == [failed])
        var bad = value; bad.pendingMoves.append(pending)
        #expect(throws:(any Error).self) { try bad.write(file:config) }
        bad = value; bad.pendingMoves = [.init(source:old,folderName:"../escape")]
        #expect(throws:(any Error).self) { try bad.write(file:config) }
        var legacy = try JSONSerialization.jsonObject(with:JSONEncoder().encode(value)) as! [String:Any]
        legacy.removeValue(forKey:"pendingMoves")
        try JSONSerialization.data(withJSONObject:legacy).write(to:config)
        #expect(try LibraryLocation.read(file:config).pendingMoves.isEmpty)
    }
    @Test func startReadsTheDestinationAtCreationAndRoutingDoesNotLockExistingCaptures() throws {
        let fixture = try Fixture(), config = fixture.root.appendingPathComponent("AppData/location.json")
        let first = fixture.root.appendingPathComponent("First"), second = fixture.root.appendingPathComponent("Second")
        try FileManager.default.createDirectory(at:first,withIntermediateDirectories:true)
        try FileManager.default.createDirectory(at:second,withIntermediateDirectories:true)
        try LibraryLocation(primary:first).write(file:config)
        try LibraryRouting.withLock(file:config,exclusive:true) {
            try LibraryLocation(primary:second).write(file:config)
            #expect(throws:(any Error).self) { try LibraryRouting.withLock(file:config,exclusive:false,wait:false) {} }
        }
        let destination = try LibraryRouting.withLock(file:config,exclusive:false) { try LibraryRouting.recordingDestination(file:config) }
        #expect(destination.resolvingSymlinksInPath() == second.resolvingSymlinksInPath())
        // A GUI bookmark is deliberately not resolved by an unsandboxed host.
        try LibraryLocation(primary:second,bookmarks:[second.path:Data("not a host bookmark".utf8)]).write(file:config)
        #expect(try LibraryRouting.recordingDestination(file:config).resolvingSymlinksInPath() == second.resolvingSymlinksInPath())
    }
    @Test func mergedSnapshotsPreferThePublishedCopyWithoutDuplicateFolderKeys() throws {
        let fixture = try Fixture(), other = fixture.root.appendingPathComponent("../Moved-" + UUID().uuidString).standardizedFileURL
        defer { try? FileManager.default.removeItem(at:other) }
        let old = try LibraryScanner(root:fixture.root).scan()
        _ = try LibraryMove.meetings(from:fixture.root,to:other)
        let current = try LibraryScanner(root:other).scan()
        let result = LibraryScan.merging([current,old])
        #expect(result.meetings.count == 1)
        #expect(result.meetings.first?.folder.deletingLastPathComponent().resolvingSymlinksInPath().path == other.resolvingSymlinksInPath().path)
        #expect(result.meetings.first?.id == old.meetings.first?.id)
    }
    @Test func locationSymlinkAndUnsupportedVersionsAreNotFollowed() throws {
        let fixture = try Fixture(), config = fixture.root.appendingPathComponent("location.json")
        let target = fixture.root.appendingPathComponent("target")
        try Data("keep".utf8).write(to:target)
        try FileManager.default.createSymbolicLink(at:config,withDestinationURL:target)
        #expect(throws:(any Error).self) { try LibraryLocation.read(file:config) }
        try LibraryLocation(primary:fixture.root).write(file:config)
        #expect(try Data(contentsOf:target) == Data("keep".utf8))
        var json = try JSONSerialization.jsonObject(with:Data(contentsOf:config)) as! [String:Any]
        json["version"] = 2; try JSONSerialization.data(withJSONObject:json).write(to:config)
        #expect(throws:(any Error).self) { try LibraryLocation.read(file:config) }
    }
    @Test func aFailedMoveCollisionKeepsBothMeetingsVisibleWithoutChangingTheirUUIDs() throws {
        let fixture = try Fixture(), other = fixture.root.appendingPathComponent("../Collision-" + UUID().uuidString).standardizedFileURL
        defer { try? FileManager.default.removeItem(at:other) }
        try FileManager.default.createDirectory(at:other,withIntermediateDirectories:true)
        try FileManager.default.copyItem(at:fixture.folder,to:other.appendingPathComponent(fixture.folder.lastPathComponent))
        let report = try LibraryMove.meetings(from:fixture.root,to:other)
        #expect(report.failed == [fixture.folder.lastPathComponent])
        let current = try LibraryScanner(root:other).scan(), old = try LibraryScanner(root:fixture.root).scan()
        let combined = LibraryScan.merging([current,old],retaining:[LibraryLocation.canonical(fixture.folder)])
        #expect(combined.meetings.count == 2)
        #expect(Set(combined.meetings.map(\.libraryKey)).count == 2)
        #expect(Set(combined.meetings.map(\.id)).count == 1)
        #expect(Set(combined.meetings.map { $0.folder.deletingLastPathComponent().path }).count == 2)
    }
}
