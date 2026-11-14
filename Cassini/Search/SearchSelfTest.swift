// SPDX-License-Identifier: GPL-3.0-or-later
#if DEBUG
import AppKit
import CassiniLibrary
import CassiniSearch
import Darwin
import Observation

/// Exercises the real app model/cache and navigation without UI automation or
/// audio playback. It reads only the bundled public Library fixture.
@MainActor enum SearchSelfTest {
    static func run() async {
        let env = ProcessInfo.processInfo.environment, context = LibraryLaunchContext.current
        let hosted = env["GITHUB_ACTIONS"] == "true" && env["RUNNER_ENVIRONMENT"] == "github-hosted"
        guard hosted || env["CASSINI_LOCAL_WORKFLOW_TESTS"] == "1", context.screenshot,
              LibraryLaunchContext.argument("-CassiniScreenshot") == "library",
              let resources = Bundle.main.resourceURL,
              context.root.resolvingSymlinksInPath().path.hasPrefix(resources.appendingPathComponent("Fixtures/Library/main").resolvingSymlinksInPath().path + "/") else { exit(78) }
        do {
            let store = LibraryStore.shared
            store.start()
            try await waitForLibrary(store)
            guard !store.meetings.isEmpty else { throw POSIXError(.EINVAL) }
            let model = LibrarySearchModel.shared
            model.query = "budget"; model.speaker = "Marta"; model.open()
            await model.waitForFixtureSearch()
            guard !model.searching, model.hits.count == 4, model.count == "4 places in 3 meetings", model.hits.map(\.positionMs) == [4000,872000,1870000,527000],
                  !model.names.contains(where:{ $0.hasPrefix("Speaker ") }) else { throw POSIXError(.EINVAL) }
            model.date = .today; model.refresh()
            await model.waitForFixtureSearch()
            guard !model.searching, model.hits.count == 2 else { throw POSIXError(.EINVAL) }
            model.speaker = "Dario"; model.refresh()
            await model.waitForFixtureSearch()
            guard !model.searching, model.hits.isEmpty else { throw POSIXError(.EINVAL) }
            model.date = .any; model.speaker = "Marta"; model.own = true; model.refresh()
            await model.waitForFixtureSearch()
            guard !model.searching, model.hits.count == 4 else { throw POSIXError(.EINVAL) }
            model.selectedID = model.hits.first(where:{ $0.positionMs == 872000 })?.id
            model.openSelected(play:false)
            guard !model.visible, MeetingNavigation.shared.detail?.meeting.title == "Budget review",
                  MeetingNavigation.shared.detail?.positionMs == 872000 else { throw POSIXError(.EINVAL) }
            model.open()
            await model.waitForFixtureSearch()
            guard !model.searching, model.query.isEmpty, model.speaker == nil, model.date == .any, !model.own, model.hits.isEmpty else { throw POSIXError(.EINVAL) }
            model.speaker = "Marta"; model.own = true
            guard let meeting = LibraryStore.shared.meetings.first else { throw POSIXError(.EINVAL) }
            MeetingNavigation.shared.open(meeting,frozen:true)
            guard !model.visible, model.speaker == nil, !model.own else { throw POSIXError(.EINVAL) }
            MeetingNavigation.shared.back()
            guard hasSelectAll(NSApp.mainMenu) else { throw POSIXError(.ENOTSUP) }
            let startup = FailFirstIndex(), failures = FailureCount()
            let recovering = LibrarySearchModel(makeIndex:{ try startup.create($0) },reportFailure:{ _ in failures.value += 1 })
            recovering.visible = true; recovering.query = "budget"; recovering.speaker = "Marta"
            recovering.update(LibraryStore.shared.meetings)
            await recovering.waitForFixtureSearch()
            guard !recovering.searching, failures.value == 1 else { throw POSIXError(.EINVAL) }
            recovering.refresh()
            await recovering.waitForFixtureSearch()
            guard !recovering.searching, recovering.hits.count == 4, failures.value == 1 else { throw POSIXError(.EINVAL) }
            recovering.close()
            try checkStarredRemoval(store)
            let report: [String:Any] = ["realAppFTS5":true,"places":4,"meetings":3,"d14Order":[4000,872000,1870000,527000],
                                      "andFilters":true,"selectAllPreserved":true,"navigationClosesSearch":true,"hitSeekMs":872000,"filtersResetOnClose":true,"indexFailureRecovers":true,"starredRemovalSelection":true,"audioDevicesOpened":false]
            FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject:report,options:[.sortedKeys]) + Data([10])); exit(0)
        } catch {
            FileHandle.standardError.write(Data("Search app self-test failed: \(error)\n".utf8)); exit(1)
        }
    }
    /// Exercise Trash's actual selection update without deleting bundled fixtures.
    private static func checkStarredRemoval(_ store: LibraryStore) throws {
        let savedPreferences = store.preferences
        defer { store.stop(); store.preferences = savedPreferences }
        store.preferences.filter = .all
        let ordered = store.groups.flatMap(\.meetings)
        guard ordered.count >= 3, let first = ordered.first, let last = ordered.last else { throw POSIXError(.EINVAL) }
        store.preferences.starredKeys = [first.libraryKey, last.libraryKey]
        store.preferences.filter = .starred
        // Fall back in visible row order across hidden unstarred rows, then
        // clear selection when the final star is removed.
        store.selectedKey = last.libraryKey
        store.removed(last)
        store.stop() // Keep the read-only fixture scan from restoring this row.
        guard store.selectedKey == first.libraryKey, store.visibleMeetings.count == 1 else { throw POSIXError(.EINVAL) }
        store.removed(first)
        store.stop()
        guard store.selectedKey == nil, store.selectedMeetings.isEmpty,
              store.visibleMeetings.isEmpty, !store.meetings.isEmpty else { throw POSIXError(.EINVAL) }
    }
    private final class FailFirstIndex: @unchecked Sendable {
        private let lock = NSLock(); private var first = true
        func create(_ cache: URL) throws -> SearchIndex {
            lock.lock(); let fail = first; first = false; lock.unlock()
            if fail { throw POSIXError(.EIO) }
            return try SearchIndex(cache:cache)
        }
    }
    @MainActor private final class FailureCount { var value = 0 }
    private static func hasSelectAll(_ menu: NSMenu?) -> Bool {
        menu?.items.contains { item in
            (item.keyEquivalent.lowercased() == "a" && item.keyEquivalentModifierMask.contains(.command)) || hasSelectAll(item.submenu)
        } ?? false
    }
    private static func waitForLibrary(_ store: LibraryStore) async throws {
        while !store.loaded {
            let (changes, continuation) = AsyncStream<Void>.makeStream()
            withObservationTracking { _ = store.loaded } onChange: {
                continuation.yield(())
                continuation.finish()
            }
            var iterator = changes.makeAsyncIterator()
            _ = await iterator.next()
            try Task.checkCancellation()
        }
    }
}
#endif
