import Foundation
import Testing
import CassiniLibrary
import CoreServices
@testable import CassiniLibraryWatchers

@Suite struct LibraryWatcherTests {
    @Test func fileEventsUseAnInjectedTemporaryRoot() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let (events, continuation) = AsyncStream<URL>.makeStream()
        let watcher: any LibraryWatching = LibraryWatcher(root: root)
        defer { watcher.stop(); continuation.finish() }
        try watcher.start { continuation.yield($0) }
        let folder = root.appendingPathComponent("Recording-" + UUID().uuidString.lowercased())
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("fixture change".utf8).write(to: folder.appendingPathComponent("meeting.json"), options: .atomic)
        let event = await withTaskGroup(of: URL?.self) { group in
            group.addTask { for await event in events { return event }; return nil }
            group.addTask { try? await Task.sleep(for: .seconds(5)); return nil }
            let first = await group.next() ?? nil; group.cancelAll(); return first
        }
        #expect(event?.path == root.path || event?.path == root.resolvingSymlinksInPath().path || event?.path == folder.resolvingSymlinksInPath().path)
        watcher.stop()
    }
    @Test func metadataTargetsOnlyItsMeetingAndWaveGrowthIsIgnored() {
        let root = URL(fileURLWithPath: "/fixture/Library", isDirectory: false)
        let folder = root.appendingPathComponent("Recording-9037a57c-c501-44e6-8f1a-56f4c9317695")
        let modified = FSEventStreamEventFlags(kFSEventStreamEventFlagItemModified)
        #expect(LibraryWatcher.target(folder.appendingPathComponent("meeting.json"), flags: modified, root: root)?.path == folder.path)
        #expect(LibraryWatcher.target(folder.appendingPathComponent("track-microphone.wav"), flags: modified, root: root) == nil)
        #expect(LibraryWatcher.target(folder.appendingPathComponent(".meeting.lock"), flags: modified, root: root) == nil)
        #expect(LibraryWatcher.target(URL(fileURLWithPath: "/fixture/Unrelated/file"), flags: modified, root: root) == nil)
        #expect(LibraryWatcher.target(folder, flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemRenamed), root: root)?.path == folder.path)
        #expect(LibraryWatcher.target(folder, flags: FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs), root: root)?.path == root.path)
    }
    @Test func trailingDebounceHasAMaximumWaitAndRootSupersedesMeetings() {
        let root = URL(fileURLWithPath: "/fixture/Library")
        let folder = root.appendingPathComponent("Recording-example")
        var batch = ChangeBatch()
        batch.add(folder, root: root, now: 10)
        #expect(batch.deadline == 10.25)
        batch.add(folder, root: root, now: 10.1)
        #expect(batch.deadline == 10.35)
        batch.add(folder, root: root, now: 11.99)
        #expect(batch.deadline == 12)
        batch.add(root, root: root, now: 12)
        #expect(batch.take() == [root])
        #expect(batch.deadline == nil)
    }

}
