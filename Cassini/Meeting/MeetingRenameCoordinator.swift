// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import Observation
import CassiniLibrary

@MainActor @Observable final class MeetingRenameCoordinator {
    enum Presentation { case sheet, title }
    static let shared = MeetingRenameCoordinator()
    var presentation: Presentation?
    var name = ""
    private(set) var meeting: LibraryMeeting?
    private(set) var working = false
    @ObservationIgnored private var task: Task<Void,Never>?
    @ObservationIgnored private var closing = false
    var normalized: String { MeetingRename.normalized(name,untitled:UXText.text("library.untitled")) }
    var canApply: Bool {
        guard let meeting else { return false }
        let original = meeting.title ?? UXText.text("library.untitled")
        return !working && name != original && normalized != original && canRename(meeting)
    }
    func canRename(_ meeting: LibraryMeeting?) -> Bool {
        guard !closing, !working, !LibraryMoveCoordinator.shared.busy, !MeetingTrashCoordinator.shared.busy,
              let meeting, meeting.state.lifecycle == .saved, !meeting.metadataReadOnly,
              !LibraryStore.shared.context.screenshot, LibraryLocationModel.shared.available, !LibraryStore.shared.offline else { return false }
        if let detail = MeetingNavigation.shared.detail, detail.meeting.folder == meeting.folder, detail.fileURL != nil { return false }
        return LibraryLocationModel.shared.roots.contains { LibraryLocation.canonical($0) == LibraryLocation.canonical(meeting.folder.deletingLastPathComponent()) }
    }
    var commandMeeting: LibraryMeeting? {
        let search = LibrarySearchModel.shared
        if search.visible { return search.searching ? nil : search.selected.flatMap { search.meeting($0) } }
        return MeetingNavigation.shared.detail?.meeting ?? LibraryStore.shared.selected
    }
    var commandEnabled: Bool {
        guard NSApp.keyWindow?.accessibilityIdentifier() == "cassini-library-window", NSApp.keyWindow?.attachedSheet == nil else { return false }
        return canRename(commandMeeting)
    }
    func show(_ meeting: LibraryMeeting, presentation: Presentation = .sheet) {
        #if DEBUG
        if MeetingRenameFixture.enabled { NSLog("Hosted rename request: allowed=%d, current=%@, requested=%@",canRename(meeting),String(describing:self.presentation),String(describing:presentation)) }
        #endif
        guard canRename(meeting), self.presentation == nil else { return }
        self.meeting = meeting; name = meeting.title ?? UXText.text("library.untitled"); self.presentation = presentation
    }
    func cancel() { presentation = nil; if !working { meeting = nil } }
    func apply() {
        guard canApply, let meeting else { return }
        working = true
        let name = self.name, untitled = UXText.text("library.untitled"), location = LibraryLocationModel.shared.location
        task = Task {
            do {
                let title = try await Task.detached(priority:.userInitiated) {
                    let access = try LibraryAccess(location,tolerateMissingPrevious:true)
                    defer { withExtendedLifetime(access) {} }
                    guard access.roots.contains(where:{ LibraryLocation.canonical($0) == LibraryLocation.canonical(meeting.folder.deletingLastPathComponent()) }) else { throw POSIXError(.EACCES) }
                    return try MeetingRename.apply(name,to:meeting,untitled:untitled)
                }.value
                if let detail = MeetingNavigation.shared.detail, detail.meeting.folder == meeting.folder, detail.fileURL == nil {
                    detail.meeting.title = title; detail.meeting.exportTitle = title
                }
                LibraryStore.shared.refresh(affected:meeting.folder)
                presentation = nil; self.meeting = nil
            } catch { if !closing { NSApp.presentError(error) } }
            working = false; task = nil; LibraryMoveCoordinator.shared.maybeRetryDeferred()
        }
    }
    func dismissForQuit() async {
        let parent = NSApp.keyWindow?.sheetParent ?? NSApp.mainWindow
        presentation = nil
        for _ in 0..<40 {
            guard parent?.attachedSheet != nil else { return }; try? await Task.sleep(for:.milliseconds(25))
        }
    }
    func beginShutdown() { closing = true; presentation = nil }
    func waitForShutdown() async { await task?.value }
}
