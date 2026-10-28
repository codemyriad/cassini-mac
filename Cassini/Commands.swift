// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import CassiniLibrary

struct AppCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    private var exportMeeting: LibraryMeeting? { detail?.meeting ?? LibraryStore.shared.selected }
    private var detail: MeetingDetailModel? { MeetingNavigation.shared.detail }
    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Open…") { LegacyOpening.chooseDocuments() }.keyboardShortcut("o", modifiers: .command)
            Button(UXText.text(RecordingController.shared.isRecording ? "common.stop" : "common.record")) {
                if RecordingConfirmation.active { RecordingConfirmation.stop() }
                else { openWindow(id: "library"); RecordCoordinator.shared.request(parent: LibraryLaunchContext.current.root) }
            }.keyboardShortcut("r", modifiers: .command).disabled(RecordingController.shared.isSaving)
        }
        CommandGroup(after: .saveItem) {
            Button(UXText.text("common.exportEllipsis")) { if let meeting = exportMeeting { MeetingExportCoordinator.shared.show(meeting) } }
                .keyboardShortcut("e", modifiers: [.command, .shift]).disabled(!MeetingExportCoordinator.canExport(exportMeeting))
        }
        CommandGroup(after: .sidebar) {
            Button(UXText.text("common.backToLibrary")) { MeetingNavigation.shared.back() }
                .keyboardShortcut("[", modifiers: .command).disabled(detail == nil)
        }
        CommandMenu("Playback") {
            Button(UXText.text(detail?.isPlaying == true ? "player.pause" : "common.play")) { detail?.toggle() }
                .keyboardShortcut(.space, modifiers: []).disabled(detail?.canPlay != true)
            Button(UXText.text("player.back10")) { detail?.skip(-10) }.keyboardShortcut(.leftArrow, modifiers: []).disabled(detail?.canPlay != true)
            Button(UXText.text("player.forward10")) { detail?.skip(10) }.keyboardShortcut(.rightArrow, modifiers: []).disabled(detail?.canPlay != true)
        }
    }
}
