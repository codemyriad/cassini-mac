// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import CassiniLibrary

struct AppCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    private var exportMeeting: LibraryMeeting? {
        let search = LibrarySearchModel.shared
        if search.visible { return search.searching ? nil : search.selected.flatMap { search.meeting($0) } }
        return detail?.meeting ?? LibraryStore.shared.selected
    }
    private var detail: MeetingDetailModel? { MeetingNavigation.shared.detail }
    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Open…") { LegacyOpening.chooseDocuments() }.keyboardShortcut("o", modifiers: .command)
            Button(RecordingOverview.recordCommandTitle) {
                if RecordingConfirmation.active { RecordingConfirmation.stop() }
                else { openWindow(id: "library"); RecordCoordinator.shared.request(parent: LibraryStore.shared.context.root) }
            }.keyboardShortcut("r", modifiers: .command).disabled(RecordingOverview.saving)
        }
        CommandGroup(after: .newItem) {
            Button(UXText.text("meeting.renameEllipsis")) {
                if let meeting = MeetingRenameCoordinator.shared.commandMeeting { MeetingRenameCoordinator.shared.show(meeting) }
            }.disabled(!MeetingRenameCoordinator.shared.commandEnabled)

            Button(UXText.text("common.exportEllipsis")) { if let meeting = exportMeeting { MeetingExportCoordinator.shared.show(meeting) } }
                .keyboardShortcut("e", modifiers: [.command, .shift]).disabled(!MeetingExportCoordinator.canExport(exportMeeting))
            Button(UXText.text("common.moveToTrash")) {
                let trash = MeetingTrashCoordinator.shared
                if trash.commandEnabled, let meeting = trash.commandMeeting { trash.move(meeting,undoManager:NSApp.keyWindow?.undoManager) }
            }.keyboardShortcut(.delete,modifiers:.command).disabled(!MeetingTrashCoordinator.shared.commandEnabled)
        }
        CommandGroup(after: .sidebar) {
            Button(UXText.text("common.backToLibrary")) {
                if LibrarySearchModel.shared.visible { LibrarySearchModel.shared.close() } else { MeetingNavigation.shared.back() }
            }
                .keyboardShortcut("[", modifiers: .command).disabled(detail == nil && !LibrarySearchModel.shared.visible)
        }
        CommandGroup(replacing:.textEditing) {
            Button(UXText.text("search.field.a11y")) { LibrarySearchModel.shared.open() }.keyboardShortcut("f",modifiers:.command)
        }
        CommandMenu("Playback") {
            Button(UXText.text(detail?.isPlaying == true ? "player.pause" : "common.play")) { detail?.toggle() }
                .keyboardShortcut(.space, modifiers: []).disabled(detail?.canPlay != true)
            Button(UXText.text("player.back10")) { detail?.skip(-10) }.keyboardShortcut(.leftArrow, modifiers: []).disabled(detail?.canPlay != true)
            Button(UXText.text("player.forward10")) { detail?.skip(10) }.keyboardShortcut(.rightArrow, modifiers: []).disabled(detail?.canPlay != true)
        }
    }
}
