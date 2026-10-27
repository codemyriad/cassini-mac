import AppKit

/// Routes bare-key media shortcuts (Space, ←, →). The Playback menu lists them as key
/// equivalents so they are discoverable, but a bare key equivalent would steal typing from the
/// search field: this monitor runs first, hands the key to an editable text view when one has
/// focus, and otherwise acts on the key window's session, so the menu never sees those keys.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var monitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        if ScreenshotFixture.launchIfRequested() { return }
        if CommandLine.arguments.contains("--whistle-self-test") {
            Task { @MainActor in await WhistleSelfTest.run() }
            return
        }
        if CommandLine.arguments.contains("--recording-self-test") || CommandLine.arguments.contains("--recording-sink-self-test") {
            Task { @MainActor in await RecordingSelfTest.run(sinkOnly: CommandLine.arguments.contains("--recording-sink-self-test")) }
            return
        }
        #endif
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            MainActor.assumeIsolated { AppDelegate.handle(event) }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { RecordingController.shared.stop() }
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { !CommandLine.arguments.contains("--recording-self-test") && !CommandLine.arguments.contains("--recording-sink-self-test") }

    @MainActor
    private static func handle(_ event: NSEvent) -> NSEvent? {
        guard event.modifierFlags.intersection([.command, .option, .control]).isEmpty,
              [49, 123, 124].contains(event.keyCode),
              let window = event.window else { return event }
        if let editor = window.firstResponder as? NSTextView, editor.isEditable {
            editor.keyDown(with: event)
            return nil
        }
        guard let session = SessionRegistry.shared.session(for: window) else { return event }
        guard let player = session.player, player.playbackError == nil else { return nil }
        switch event.keyCode {
        case 49:  // Space
            player.toggle()
        case 123:  // ←
            session.seek(toMs: player.currentMs - 15_000)
        case 124:  // →
            session.seek(toMs: player.currentMs + 15_000)
        default:
            return event
        }
        return nil
    }
}

/// The open sessions, so window-level events can find their model.
@MainActor
final class SessionRegistry {
    static let shared = SessionRegistry()

    private struct Weak { weak var session: SessionModel? }
    private var sessions: [Weak] = []

    func register(_ session: SessionModel) {
        sessions.removeAll { $0.session == nil }
        sessions.append(Weak(session: session))
    }

    func session(for window: NSWindow) -> SessionModel? {
        sessions.first { $0.session?.window === window }?.session
    }
}
