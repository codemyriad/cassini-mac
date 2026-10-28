// SPDX-License-Identifier: GPL-3.0-or-later
#if DEBUG
import AppKit
import CassiniLibrary
import CassiniSearch
import Darwin

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
            LibraryStore.shared.start()
            try await wait { LibraryStore.shared.loaded && !LibraryStore.shared.meetings.isEmpty }
            let model = LibrarySearchModel.shared
            model.query = "budget"; model.speaker = "Marta"; model.open()
            try await wait { !model.searching && model.hits.count == 4 }
            guard model.count == "4 places in 3 meetings", model.hits.map(\.positionMs) == [4000,872000,1870000,527000],
                  !model.names.contains(where:{ $0.hasPrefix("Speaker ") }) else { throw POSIXError(.EINVAL) }
            model.date = .today; model.refresh()
            try await wait { !model.searching && model.hits.count == 2 }
            model.speaker = "Dario"; model.refresh()
            try await wait { !model.searching && model.hits.isEmpty }
            model.date = .any; model.speaker = "Marta"; model.own = true; model.refresh()
            try await wait { !model.searching && model.hits.count == 4 }
            model.selectedID = model.hits.first(where:{ $0.positionMs == 872000 })?.id
            model.openSelected(play:false)
            guard !model.visible, MeetingNavigation.shared.detail?.meeting.title == "Budget review",
                  MeetingNavigation.shared.detail?.positionMs == 872000 else { throw POSIXError(.EINVAL) }
            model.open()
            try await wait { !model.searching }
            guard model.query.isEmpty, model.speaker == nil, model.date == .any, !model.own, model.hits.isEmpty else { throw POSIXError(.EINVAL) }
            model.speaker = "Marta"; model.own = true
            guard let meeting = LibraryStore.shared.meetings.first else { throw POSIXError(.EINVAL) }
            MeetingNavigation.shared.open(meeting,frozen:true)
            guard !model.visible, model.speaker == nil, !model.own else { throw POSIXError(.EINVAL) }
            MeetingNavigation.shared.back()
            guard hasSelectAll(NSApp.mainMenu) else { throw POSIXError(.ENOTSUP) }
            let report: [String:Any] = ["realAppFTS5":true,"places":4,"meetings":3,"d14Order":[4000,872000,1870000,527000],
                                      "andFilters":true,"selectAllPreserved":true,"navigationClosesSearch":true,"hitSeekMs":872000,"filtersResetOnClose":true,"audioDevicesOpened":false]
            FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject:report,options:[.sortedKeys]) + Data([10])); exit(0)
        } catch {
            FileHandle.standardError.write(Data("Search app self-test failed: \(error)\n".utf8)); exit(1)
        }
    }
    private static func hasSelectAll(_ menu: NSMenu?) -> Bool {
        menu?.items.contains { item in
            (item.keyEquivalent.lowercased() == "a" && item.keyEquivalentModifierMask.contains(.command)) || hasSelectAll(item.submenu)
        } ?? false
    }
    private static func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<150 { if condition() { return }; try await Task.sleep(for:.milliseconds(100)) }
        throw POSIXError(.ETIMEDOUT)
    }
}
#endif
