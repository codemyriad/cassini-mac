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
            try await checkSearchPreviewToolbarAndRefocus(store, model: model)
            try checkStarredRemoval(store)
            let report: [String:Any] = ["realAppFTS5":true,"places":4,"meetings":3,"d14Order":[4000,872000,1870000,527000],
                                      "andFilters":true,"selectAllPreserved":true,"navigationClosesSearch":true,"hitSeekMs":872000,"filtersResetOnClose":true,"indexFailureRecovers":true,"starredRemovalSelection":true,"searchPreviewTargetsB":true,"searchRefocusAfterSelectAndDismiss":true,"audioDevicesOpened":false]
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
    /// Regression checks for D-1172 review findings:
    /// 1) Opening meeting A, searching, and selecting a hit from B targets B (not A) in the detail toolbar.
    /// 2) Pressing ⌘F / ⌥⌘F after selecting a result or dismissing search always increments both
    ///    `sidebarFocusRequest` and `focusRequest` and focuses a mounted `NSSearchField`.
    private static func checkSearchPreviewToolbarAndRefocus(_ store: LibraryStore, model: LibrarySearchModel) async throws {
        defer {
            model.close()
            MeetingNavigation.shared.back()
        }
        guard let meetingA = store.meetings.first(where: { $0.state.lifecycle == .saved && $0.title != "Budget review" }),
              let meetingB = store.meetings.first(where: { $0.state.lifecycle == .saved && $0.title == "Budget review" }),
              meetingA.libraryKey != meetingB.libraryKey else {
            throw POSIXError(.EINVAL)
        }
        MeetingNavigation.shared.open(meetingA, frozen: true)
        guard MeetingNavigation.shared.savedDetail?.meeting.libraryKey == meetingA.libraryKey else {
            throw POSIXError(.EINVAL)
        }
        model.query = "budget"
        model.open()
        await model.waitForFixtureSearch()
        guard let hitB = model.hits.first(where: { $0.meetingKey == meetingB.libraryKey }) else {
            throw POSIXError(.EINVAL)
        }
        model.selectedID = hitB.id
        let resolvedTarget = LibraryDetailToolbarTarget.resolve(
            searchVisible: model.visible,
            searchPreviewMeeting: model.selected.flatMap { model.meeting($0) },
            savedDetailMeeting: MeetingNavigation.shared.savedDetail?.meeting,
            recordingSelected: false,
            selectedMeeting: store.selected
        )
        guard resolvedTarget.meeting?.libraryKey == meetingB.libraryKey,
              !resolvedTarget.showsFindAction,
              !resolvedTarget.showsCompactHeader,
              !resolvedTarget.showsTrashAction else {
            throw POSIXError(.EINVAL)
        }

        // Refocus while search is visible after selecting a result.
        let beforeSelectSidebar = model.sidebarFocusRequest
        let beforeSelectFocus = model.focusRequest
        model.requestSidebarFocus()
        guard model.sidebarFocusRequest == beforeSelectSidebar &+ 1,
              model.focusRequest == beforeSelectFocus &+ 1 else {
            throw POSIXError(.EINVAL)
        }

        // Refocus after dismissing search.
        model.close()
        guard !model.visible else { throw POSIXError(.EINVAL) }
        let beforeDismissSidebar = model.sidebarFocusRequest
        let beforeDismissFocus = model.focusRequest
        model.requestSidebarFocus()
        guard model.sidebarFocusRequest == beforeDismissSidebar &+ 1,
              model.focusRequest == beforeDismissFocus &+ 1 else {
            throw POSIXError(.EINVAL)
        }

        // Verify mounted NSSearchField refocuses when another control holds first responder.
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 120), styleMask: [.titled], backing: .buffered, defer: false)
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 120))
        let otherButton = NSButton(title: "Other", target: nil, action: nil)
        let searchField = NSSearchField(frame: NSRect(x: 10, y: 40, width: 200, height: 24))
        searchField.stringValue = "budget"
        container.addSubview(otherButton)
        container.addSubview(searchField)
        window.contentView = container
        _ = window.makeFirstResponder(otherButton)
        guard SidebarSearchFocus.focusMountedSearchField(in: window) else {
            throw POSIXError(.EINVAL)
        }
        let responder = window.firstResponder
        let focusedField = (responder === searchField) || (searchField.currentEditor() != nil && responder === searchField.currentEditor())
        guard focusedField else { throw POSIXError(.EINVAL) }
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
