// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

@main struct ImportedMeetingNoticeStateProbe {
    @MainActor static func main() throws {
        let suite = "io.codemyriad.cassini.import-notice-proof." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let visible = ImportedMeetingNotice.Visibility(appIsActive: true, isKeyWindow: true, hasSheet: false, contentIsVisible: true)
        let inactive = ImportedMeetingNotice.Visibility(appIsActive: true, isKeyWindow: false, hasSheet: false, contentIsVisible: true)
        let appInactive = ImportedMeetingNotice.Visibility(appIsActive: false, isKeyWindow: true, hasSheet: false, contentIsVisible: true)
        let sheet = ImportedMeetingNotice.Visibility(appIsActive: true, isKeyWindow: true, hasSheet: true, contentIsVisible: true)
        let hidden = ImportedMeetingNotice.Visibility(appIsActive: true, isKeyWindow: true, hasSheet: false, contentIsVisible: false)
        let a = ImportedMeetingNotice.Candidate(id: UUID(), folderName: "Downloads")
        let b = ImportedMeetingNotice.Candidate(id: UUID(), folderName: nil)
        let c = ImportedMeetingNotice.Candidate(id: UUID(), folderName: "Documents")
        let state = ImportedMeetingNotice(defaults: defaults)

        state.update(candidate: a, visibility: inactive)
        try expect(state.notice == nil, "A background window cannot present a notice")
        state.update(candidate: a, visibility: appInactive)
        try expect(state.notice == nil, "An inactive app cannot present even if its window retains key state")
        state.update(candidate: a, visibility: visible)
        try expect(state.notice == a, "The inactive update must not consume the first appearance")
        state.update(candidate: a, visibility: sheet)
        state.didAppear(a.id, visibility: sheet)
        try expect(state.notice == nil, "A sheet arriving before appearance defers the notice")
        state.update(candidate: a, visibility: visible)
        try expect(state.notice == a, "Closing the sheet retries the unconsumed notice")
        state.didAppear(a.id, visibility: visible)
        state.update(candidate: a, visibility: visible)
        try expect(state.notice == a, "Persisting seen must not immediately remove a visible receipt")
        state.dismiss(a.id)
        state.update(candidate: a, visibility: visible)
        try expect(state.notice == nil, "A dismissed, actually shown notice stays consumed")

        let reopened = ImportedMeetingNotice(defaults: UserDefaults(suiteName: suite)!)
        reopened.update(candidate: a, visibility: visible)
        try expect(reopened.notice == nil, "A new controller observes the persisted seen flag")
        state.update(candidate: b, visibility: visible)
        try expect(state.notice?.folderName == nil && state.notice?.id == b.id, "An absent source folder remains absent")
        state.update(candidate: c, visibility: visible)
        state.didAppear(b.id, visibility: visible)
        state.dismiss(b.id)
        try expect(state.notice == c, "Late callbacks for an old meeting cannot dismiss the new notice")
        reopened.update(candidate: b, visibility: visible)
        try expect(reopened.notice == b, "A late appearance cannot consume a meeting that never appeared")
        state.didAppear(c.id, visibility: hidden)
        try expect(state.notice == nil, "Visibility is checked again at actual appearance")
        state.update(candidate: c, visibility: visible)
        try expect(state.notice == c, "A hidden appearance must not consume its seen flag")
        state.didAppear(c.id, visibility: visible)
        state.update(candidate: c, visibility: inactive)
        state.update(candidate: c, visibility: visible)
        try expect(state.notice == nil, "A shown notice does not repeat when a window becomes key again")
        state.update(candidate: b, visibility: hidden)
        try expect(state.notice == nil, "A nonvisible pane cannot prepare a notice")
        state.update(candidate: b, visibility: visible)
        try expect(state.notice == b, "Another imported meeting keeps its independent first appearance")
        state.update(candidate: nil, visibility: visible)
        state.didAppear(b.id, visibility: visible)
        reopened.update(candidate: b, visibility: visible)
        try expect(reopened.notice == b, "Navigating away before appearance does not consume the old meeting")
        print("PASS imported notice visibility, sheet deferral, stale callbacks and persisted first appearance")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw NSError(domain: "ImportedMeetingNoticeStateProbe", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
}
