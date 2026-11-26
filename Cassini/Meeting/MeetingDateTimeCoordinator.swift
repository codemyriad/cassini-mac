// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import Observation
import CassiniLibrary

@MainActor @Observable final class MeetingDateTimeCoordinator {
    static let shared = MeetingDateTimeCoordinator()
    var showing = false
    var selectedDay = Date() { didSet { if !applyingPrefill { userEdited = true } } }
    var selectedClock = Date() { didSet { if !applyingPrefill { userEdited = true } } }
    private(set) var fromFileSavedTime = false
    private(set) var meeting: LibraryMeeting?
    private(set) var working = false
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private let prefillLoader = MeetingDateTime.PrefillLoader()
    @ObservationIgnored private var applyingPrefill = false
    @ObservationIgnored private var userEdited = false
    @ObservationIgnored private var closing = false

    func canSetDateTime(_ meeting: LibraryMeeting?) -> Bool {
        guard !closing, !working, !LibraryMoveCoordinator.shared.busy, !MeetingTrashCoordinator.shared.busy,
              !MeetingRenameCoordinator.shared.working,
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
        return canSetDateTime(commandMeeting)
    }

    func show(_ meeting: LibraryMeeting) {
        guard canSetDateTime(meeting), !showing, MeetingRenameCoordinator.shared.presentation == nil else { return }
        let now = LibraryStore.shared.context.now ?? Date()
        let timeZone = LibraryStore.shared.format.timeZone
        self.meeting = meeting
        userEdited = false
        showing = true
        prefillLoader.load(for: meeting, now: now, timeZone: timeZone) { [weak self] prefill, isPending in
            guard let self, self.showing, self.meeting?.folder == meeting.folder else { return }
            if !isPending && (self.userEdited || self.working) { return }
            self.applyingPrefill = true
            self.selectedDay = prefill.date
            self.selectedClock = prefill.date
            self.fromFileSavedTime = prefill.fromFileSavedTime
            self.applyingPrefill = false
        }
    }

    func cancel() {
        prefillLoader.cancel()
        showing = false
        if !working {
            meeting = nil
            fromFileSavedTime = false
            userEdited = false
        }
    }

    func apply() {
        guard !working, let meeting, canSetDateTime(meeting) else { return }
        prefillLoader.cancel()
        working = true
        let timeZone = LibraryStore.shared.format.timeZone
        let combined = MeetingDateTime.combine(day: selectedDay, clock: selectedClock, timeZone: timeZone)
        let location = LibraryLocationModel.shared.location
        let scanner = LibraryStore.shared.scannerForRename(meeting) ?? LibraryScanner(root: meeting.folder.deletingLastPathComponent())
        task = Task {
            do {
                let updated = try await Task.detached(priority: .userInitiated) {
                    let access = try LibraryAccess(location, tolerateMissingPrevious: true)
                    defer { withExtendedLifetime(access) {} }
                    guard access.roots.contains(where: { LibraryLocation.canonical($0) == LibraryLocation.canonical(meeting.folder.deletingLastPathComponent()) }) else {
                        throw POSIXError(.EACCES)
                    }
                    try MeetingDateTime.apply(combined, timeZone: timeZone, to: meeting)
                    guard let updated = try scanner.scan(affected: meeting.folder).meetings.first(where: { $0.folder == meeting.folder }) else {
                        throw POSIXError(.ENOENT)
                    }
                    return updated
                }.value
                if let detail = MeetingNavigation.shared.detail, detail.meeting.folder == meeting.folder, detail.fileURL == nil {
                    detail.meeting.start = updated.start
                    detail.meeting.recordedTime = updated.recordedTime
                    detail.meeting.userStartedAt = updated.userStartedAt
                    detail.meeting.recordingUtcOffsetMinutes = updated.recordingUtcOffsetMinutes
                }
                LibraryStore.shared.refresh(affected: meeting.folder)
                showing = false
                self.meeting = nil
                fromFileSavedTime = false
            } catch {
                if !closing { NSApp.presentError(error) }
            }
            working = false
            task = nil
            LibraryMoveCoordinator.shared.maybeRetryDeferred()
        }
    }

    func dismissForQuit() async {
        prefillLoader.cancel()
        let parent = NSApp.keyWindow?.sheetParent ?? NSApp.mainWindow
        showing = false
        for _ in 0..<40 {
            guard parent?.attachedSheet != nil else { return }
            try? await Task.sleep(for: .milliseconds(25))
        }
    }

    func beginShutdown() { closing = true; prefillLoader.cancel(); showing = false }
    func waitForShutdown() async { await task?.value }
}
