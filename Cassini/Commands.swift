import SwiftUI

/// Menu bar commands, so every shortcut is discoverable and remappable in System Settings.
/// Space, ← and → are handled by the app delegate's key monitor (see there for why) and listed
/// here without key equivalents.
struct AppCommands: Commands {
    @FocusedValue(\.session) private var session

    var body: some Commands {
        CommandGroup(replacing: .newItem) {}

        CommandGroup(after: .saveItem) {
            Button("Export Transcript…") { if let session { TranscriptExportPanel.run(for: session) } }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(session?.timeline == nil)
            Button("Show in Finder") { session?.showInFinder() }
                .disabled(session?.fileURL == nil)
        }

        CommandGroup(after: .textEditing) {
            Button("Find…") { session?.focusSearchRequest += 1 }
                .keyboardShortcut("f", modifiers: .command)
            Button("Find Next") { session?.findNext() }
                .keyboardShortcut("g", modifiers: .command)
                .disabled(session?.matchCount == 0)
            Button("Find Previous") { session?.findPrevious() }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .disabled(session?.matchCount == 0)
        }

        CommandMenu("Playback") {
            Button(session?.player?.isPlaying == true ? "Pause" : "Play") { session?.player?.toggle() }
                .disabled(session?.player == nil)
            Button("Skip Back 15 Seconds") { if let s = session, let p = s.player { s.seek(toMs: p.currentMs - PlayerController.skipMs) } }
                .disabled(session?.player == nil)
            Button("Skip Forward 15 Seconds") { if let s = session, let p = s.player { s.seek(toMs: p.currentMs + PlayerController.skipMs) } }
                .disabled(session?.player == nil)
            Divider()
            Button("Faster") { session?.player?.stepSpeed(1) }
                .keyboardShortcut(.upArrow, modifiers: .command)
                .disabled(session?.player == nil)
            Button("Slower") { session?.player?.stepSpeed(-1) }
                .keyboardShortcut(.downArrow, modifiers: .command)
                .disabled(session?.player == nil)
            Divider()
            Toggle("Follow Along", isOn: Binding(
                get: { session?.follow ?? true },
                set: { on in session?.follow = on; if on { session?.jumpToCurrent() } }
            ))
            .keyboardShortcut("l", modifiers: .command)
            .disabled(session?.timeline == nil)
            Button("Jump to Current Word") { session?.jumpToCurrent() }
                .keyboardShortcut("j", modifiers: .command)
                .disabled(session?.timeline == nil)
        }

        CommandGroup(after: .sidebar) {
            Toggle("Show Inspector", isOn: Binding(
                get: { session?.showInspector ?? false },
                set: { session?.showInspector = $0 }
            ))
            .keyboardShortcut("i", modifiers: [.command, .option])
            .disabled(session == nil)
        }
    }
}
