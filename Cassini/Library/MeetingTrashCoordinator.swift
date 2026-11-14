// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import CassiniLibrary
import Observation

@MainActor @Observable final class MeetingTrashCoordinator {
    static let shared = MeetingTrashCoordinator()
    private(set) var busy = false
    private(set) var failure: LibraryMeeting?
    #if DEBUG
    private(set) var lastTrashEntry: TrashEntry?
    private(set) var lastTrashURL: URL?
    private(set) var lastUndoAvailable = false
    var fixtureFailure: Error?
    #endif
    @ObservationIgnored private var task: Task<Void,Never>?
    @ObservationIgnored private var restoration: Task<Void,Never>?
    @ObservationIgnored private var closing = false

    func canTrash(_ meeting: LibraryMeeting?) -> Bool {
        guard !closing, !busy, !LibraryMoveCoordinator.shared.busy, !MeetingRenameCoordinator.shared.working,
              !LibrarySearchModel.shared.visible, let meeting,
              meeting.state.lifecycle == .saved else { return false }
        if let detail = MeetingNavigation.shared.detail, detail.meeting.folder == meeting.folder, detail.fileURL != nil { return false }
        return LibraryLocationModel.shared.available && !LibraryStore.shared.offline &&
            LibraryLocationModel.shared.roots.contains { LibraryLocation.canonical($0) == LibraryLocation.canonical(meeting.folder.deletingLastPathComponent()) }
    }
    var commandMeeting: LibraryMeeting? { MeetingNavigation.shared.detail?.meeting ?? LibraryStore.shared.selected }
    var commandEnabled: Bool {
        guard NSApp.keyWindow?.identifier?.rawValue == "library" || NSApp.keyWindow?.accessibilityIdentifier() == "cassini-library-window" else { return false }
        // Leave the text system's delete/undo handling alone, including notes,
        // title edits and Search. A field editor is an NSTextView too.
        guard !(NSApp.keyWindow?.firstResponder is NSText) else { return false }
        return canTrash(commandMeeting)
    }
    func move(_ meeting: LibraryMeeting, undoManager: UndoManager?) {
        guard canTrash(meeting) else { return }
        MeetingRenameCoordinator.shared.cancel()
        busy = true; failure = nil
        task = Task {
            let location = LibraryLocationModel.shared
            var previousMoves: [LibraryPendingMove]?
            do {
                let access = try LibraryAccess(location.location,tolerateMissingPrevious:true)
                if MeetingNavigation.shared.detail?.meeting.folder == meeting.folder { MeetingNavigation.shared.back() }
                SessionPlaybackController.stopAll()
                await MeetingExportCoordinator.shared.discard(meeting.folder)
                await TranscriptionQueue.shared.cancel(meeting:meeting.folder)
                await RecordingPageModel.discard(for:meeting.folder)
                previousMoves = location.location.pendingMoves
                try location.setMovesPreservingRoots(location.location.pendingMoves.filter { $0.id != meeting.folder.path })
                #if DEBUG
                let injected = RecordingFixture.enabled ? fixtureFailure : nil
                #else
                let injected: Error? = nil
                #endif
                let now = LibraryStore.shared.context.now ?? Date()
                let entry = try await Task.detached(priority:.userInitiated) { [access] in
                    defer { withExtendedLifetime(access) {} }
                    if let injected { throw injected }
                    return try LibraryTrash.trashMeeting(meeting,roots:access.roots,now:now)
                }.value
                LibraryStore.shared.removed(meeting)
                RecentlyDeletedModel.shared.refresh()
                #if DEBUG
                lastTrashEntry = entry
                lastTrashURL = entry.map {
                    $0.root
                        .appendingPathComponent(LibraryTrash.trashDirectory,isDirectory:true)
                        .appendingPathComponent($0.entryId,isDirectory:true)
                        .appendingPathComponent(meeting.folder.lastPathComponent,isDirectory:true)
                }
                lastUndoAvailable = entry != nil && undoManager != nil
                #endif
                if let entry, let undoManager {
                    undoManager.registerUndo(withTarget:self) { target in
                        target.restore(entry,originalFolder:meeting.folder,access:access)
                    }
                    undoManager.setActionName(UXText.text("meeting.moveToRecentlyDeleted"))
                }
            } catch {
                if let previousMoves { try? location.setMovesPreservingRoots(previousMoves) }
                failure = meeting
                LibraryStore.shared.selectedKey = meeting.libraryKey; LibraryStore.shared.refresh(affected:meeting.folder)
            }
            TranscriptionQueue.shared.releaseTrashed(meeting.folder)
            busy = false; task = nil
            LibraryMoveCoordinator.shared.maybeRetryDeferred()
        }
    }
    private func restore(_ entry: TrashEntry, originalFolder: URL, access: LibraryAccess) {
        guard !closing else { return }
        let preceding = restoration
        let untitled = UXText.text("library.untitled")
        restoration = Task {
            await preceding?.value
            // Undo must not silently disappear if another Trash or Library Move
            // is still finishing. Serialize the restoration after it instead.
            while busy || LibraryMoveCoordinator.shared.busy {
                if closing { return }
                try? await Task.sleep(for:.milliseconds(25))
            }
            guard !closing else { return }; busy = true
            do {
                try await Task.detached { [access] in
                    defer { withExtendedLifetime(access) {} }
                    try LibraryTrash.restore(entryId:entry.entryId,in:entry.root,untitled:untitled)
                }.value
                LibraryStore.shared.refresh(affected:originalFolder)
                RecentlyDeletedModel.shared.refresh()
            } catch { NSApp.presentError(error) }
            busy = false
        }
    }
    func beginShutdown() { closing = true }
    func waitForShutdown() async { await task?.value; await restoration?.value }
}
