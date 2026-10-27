// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

struct AppCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    private var detail: MeetingDetailModel? { MeetingNavigation.shared.detail }
    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Open…") { LegacyOpening.chooseDocuments() }.keyboardShortcut("o", modifiers: .command)
            Button(UXText.text("common.record")) {
                if RecordingConfirmation.active { RecordingConfirmation.stop() }
                else { SessionPlaybackController.stopAll(); openWindow(id: "recording") }
            }.keyboardShortcut("r", modifiers: .command)
        }
        CommandGroup(after: .saveItem) {
            Button(UXText.text("common.exportEllipsis")) {}.keyboardShortcut("e", modifiers: [.command, .shift]).disabled(true)
        }
        CommandGroup(after: .sidebar) {
            Button(UXText.text("common.backToLibrary")) { MeetingNavigation.shared.back() }
                .keyboardShortcut("[", modifiers: .command).disabled(detail == nil)
        }
        CommandMenu(UXText.text("player.a11y")) {
            Button(UXText.text(detail?.isPlaying == true ? "player.pause" : "common.play")) { detail?.toggle() }
                .keyboardShortcut(.space, modifiers: []).disabled(detail?.canPlay != true)
            Button(UXText.text("player.back10")) { detail?.skip(-10) }.keyboardShortcut(.leftArrow, modifiers: []).disabled(detail?.canPlay != true)
            Button(UXText.text("player.forward10")) { detail?.skip(10) }.keyboardShortcut(.rightArrow, modifiers: []).disabled(detail?.canPlay != true)
        }
    }
}
