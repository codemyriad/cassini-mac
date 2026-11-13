// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import CassiniLibrary

struct AppCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @FocusedValue(\.listeningMeeting) private var listeningMeeting
    @FocusedValue(\.playTranscriptTurn) private var focusedTranscriptPlay
    private var transcriptPlay: (() -> Void)? {
        guard listeningMeeting?.canUseTranscriptShortcuts == true else { return nil }
        if let text = NSApp.keyWindow?.firstResponder as? MeetingTurnTextView { return text.playFromHere }
        if let name = NSApp.keyWindow?.firstResponder as? MeetingTurnTextView.InlineListenButton { return name.playFromHere }
        return focusedTranscriptPlay
    }
    private var exportMeeting: LibraryMeeting? {
        let search = LibrarySearchModel.shared
        if search.visible { return search.searching ? nil : search.selected.flatMap { search.meeting($0) } }
        return detail?.meeting ?? LibraryStore.shared.selected
    }
    private var detail: MeetingDetailModel? { MeetingNavigation.shared.detail }
    var body: some Commands {
        let _ = ApplicationWindows.install(window:openWindow,settings:openSettings)
        CommandGroup(after: .appInfo) {
            Button(UXText.text("app.checkForUpdates")) { ApplicationUpdates.shared.checkForUpdates() }
                .disabled(!ApplicationUpdates.shared.canCheckForUpdates)
        }
        CommandGroup(replacing:.help) { }
        CommandGroup(replacing: .newItem) {
            Button(UXText.mac("menu.open")) { LegacyOpening.chooseDocuments() }.keyboardShortcut("o", modifiers: .command)
            Button(RecordingOverview.recordCommandTitle) {
                if RecordingConfirmation.active { RecordingConfirmation.stop() }
                else { openWindow(id: "library"); RecordCoordinator.shared.request(parent: LibraryStore.shared.context.root) }
            }.keyboardShortcut("r", modifiers: .command).disabled(!RecordingConfirmation.active && !RecordingOverview.canStart)
        }
        CommandGroup(after: .newItem) {
            Button(UXText.text("meeting.renameEllipsis")) {
                if let meeting = MeetingRenameCoordinator.shared.commandMeeting { MeetingRenameCoordinator.shared.show(meeting) }
            }.disabled(!MeetingRenameCoordinator.shared.commandEnabled)

            Button(UXText.text("common.exportEllipsis")) { if let meeting = exportMeeting { MeetingExportCoordinator.shared.show(meeting) } }
                .keyboardShortcut("e", modifiers: [.command, .shift]).disabled(!MeetingExportCoordinator.canExport(exportMeeting))
            if BulkZipExportCoordinator.shared.hasSelection {
                Button(UXText.text("export.zip.selected")) { BulkZipExportCoordinator.shared.exportSelected() }
                    .disabled(!BulkZipExportCoordinator.shared.canExportSelected)
            }
            Button(UXText.text("export.zip.all")) { BulkZipExportCoordinator.shared.exportAll() }
                .disabled(!BulkZipExportCoordinator.shared.canExportAll)
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
            Button(UXText.text(detail == nil ? "search.field.a11y" : "meeting.find.placeholder")) {
                if let detail, detail.meeting.state.lifecycle == .saved, detail.showsTranscript { detail.find.requestFocus() }
                else { LibrarySearchModel.shared.open() }
            }.keyboardShortcut("f",modifiers:.command).disabled(detail?.showsTranscript == false)
        }
        CommandMenu(UXText.mac("menu.playback")) {
            Button(UXText.text(detail?.isPlaying == true ? "player.pause" : "common.play")) { detail?.toggle() }
                .keyboardShortcut(.space, modifiers: []).disabled(detail?.canPlay != true || detail?.find.focused == true)
            Button(UXText.text("player.back10")) { detail?.skip(-10) }.keyboardShortcut(.leftArrow, modifiers: []).disabled(detail?.canPlay != true)
            Button(UXText.text("player.forward10")) { detail?.skip(10) }.keyboardShortcut(.rightArrow, modifiers: []).disabled(detail?.canPlay != true)
            Divider()
            Button(UXText.text("shortcuts.playTurn")) { transcriptPlay?() }
                .keyboardShortcut(.return,modifiers:.shift).disabled(transcriptPlay == nil)
            Divider()
            Button(UXText.text("listen.previousTurn")) { if listeningMeeting?.canUseListeningShortcuts == true { listeningMeeting?.stepListeningTurn(-1) } }
                .keyboardShortcut(.upArrow,modifiers:[.option,.command])
                .disabled(listeningMeeting?.canUseListeningCommands != true || listeningMeeting?.canStepListeningTurn(-1) != true)
            Button(UXText.text("listen.nextTurn")) { if listeningMeeting?.canUseListeningShortcuts == true { listeningMeeting?.stepListeningTurn(1) } }
                .keyboardShortcut(.downArrow,modifiers:[.option,.command])
                .disabled(listeningMeeting?.canUseListeningCommands != true || listeningMeeting?.canStepListeningTurn(1) != true)
            Button(UXText.text("listen.previousSpeaker")) { if listeningMeeting?.canUseListeningShortcuts == true { listeningMeeting?.stepListeningSpeaker(-1) } }
                .keyboardShortcut(.upArrow,modifiers:[.option,.shift,.command])
                .disabled(listeningMeeting?.canUseListeningCommands != true || listeningMeeting?.canStepListeningSpeaker(-1) != true)
            Button(UXText.text("listen.nextSpeaker")) { if listeningMeeting?.canUseListeningShortcuts == true { listeningMeeting?.stepListeningSpeaker(1) } }
                .keyboardShortcut(.downArrow,modifiers:[.option,.shift,.command])
                .disabled(listeningMeeting?.canUseListeningCommands != true || listeningMeeting?.canStepListeningSpeaker(1) != true)
        }
    }
}
