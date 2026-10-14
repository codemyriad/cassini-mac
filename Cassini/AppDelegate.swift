import AppKit

/// Routes bare-key media shortcuts (Space, ←, →) to the session of the key window, unless the
/// user is typing in a text field. A menu key equivalent without modifiers would steal those keys
/// from the search field; a local event monitor can look at the first responder first.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var monitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            MainActor.assumeIsolated { AppDelegate.handle(event) }
        }
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { false }

    @MainActor
    private static func handle(_ event: NSEvent) -> NSEvent? {
        guard event.modifierFlags.intersection([.command, .option, .control]).isEmpty,
              let window = event.window,
              let session = SessionRegistry.shared.session(for: window),
              let player = session.player else { return event }
        if let editor = window.firstResponder as? NSTextView, editor.isEditable { return event }
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
