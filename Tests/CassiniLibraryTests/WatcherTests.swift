import Foundation
import Testing
import CassiniLibrary
import CassiniLibraryWatchers

@Suite struct LibraryWatcherTests {
    @Test func fileEventsUseAnInjectedTemporaryRoot() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let (events, continuation) = AsyncStream<URL>.makeStream()
        let watcher: any LibraryWatching = LibraryWatcher(root: root)
        defer { watcher.stop(); continuation.finish() }
        try watcher.start { continuation.yield($0) }
        try Data("fixture change".utf8).write(to: root.appendingPathComponent("meeting.json"), options: .atomic)
        let event = await withTaskGroup(of: URL?.self) { group in
            group.addTask { for await event in events { return event }; return nil }
            group.addTask { try? await Task.sleep(for: .seconds(5)); return nil }
            let first = await group.next() ?? nil; group.cancelAll(); return first
        }
        #expect(event == root)
        watcher.stop()
    }
}
