// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit

/// Routes bare-key media shortcuts (Space, ←, →). The Playback menu lists them as key
/// equivalents so they are discoverable, but a bare key equivalent would steal typing from the
/// search field: this monitor runs first, hands the key to an editable text view when one has
/// focus, and otherwise acts on the key window's session, so the menu never sees those keys.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var monitor: Any?
    private var confirmingQuit = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            MainActor.assumeIsolated { AppDelegate.handle(event) }
        }

        #if DEBUG
        if RecordingFixture.enabled { NSLog("Hosted recording fixture launch: %@", CommandLine.arguments) }
        if CommandLine.arguments.contains("--fixture-library-recording"), !RecordingFixture.enabled || RecordingFixture.root == nil {
            NSLog("Invalid hosted recording fixture: enabled=%d, root=%@, arguments=%@", RecordingFixture.enabled, String(describing: RecordingFixture.root), CommandLine.arguments)
            NSApp.terminate(nil); return
        }
        if CommandLine.arguments.contains("--recording-comfort-self-test") {
            Task { @MainActor in await RecordingComfortSelfTest.run() }; return
        }
        if ScreenshotFixture.launchIfRequested() {
            if RecordingFixture.enabled || RecordingPageFixture.enabled { RecordingRuntime.shared.start() }
            return
        }
        if CommandLine.arguments.contains("--whistle-self-test") {
            Task { @MainActor in await WhistleSelfTest.run() }
            return
        }
        if CommandLine.arguments.contains("--recording-self-test") || CommandLine.arguments.contains("--recording-sink-self-test") {
            Task { @MainActor in await RecordingSelfTest.run(sinkOnly: CommandLine.arguments.contains("--recording-sink-self-test")) }
            return
        }
        #endif
        RecordingRuntime.shared.start()
        LibraryStore.shared.start()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !confirmingQuit else { return .terminateLater }
        if !RecordingConfirmation.active {
            let queue = TranscriptionQueue.shared
            let wait = RecordingController.shared.isSaving || queue.isBusy || RecordingPageModel.hasPendingEdits
            queue.beginShutdown()
            guard wait else { return .terminateNow }
            confirmingQuit = true
            DispatchQueue.main.async { [weak self] in
                Task { @MainActor in
                    await RecordingPageModel.flushAll()
                    await RecordingController.shared.finishTask?.value
                    await queue.waitForShutdown()
                    self?.confirmingQuit = false; sender.reply(toApplicationShouldTerminate:true)
                }
            }
            return .terminateLater
        }
        confirmingQuit = true
        DispatchQueue.main.async { [weak self] in
            RecordingConfirmation.ask(window: sender.keyWindow ?? sender.mainWindow) { stop in
                Task { @MainActor in
                    if stop {
                        TranscriptionQueue.shared.beginShutdown()
                        await RecordingConfirmation.stopAndWait()
                        await TranscriptionQueue.shared.waitForShutdown()
                    }
                    self?.confirmingQuit = false
                    sender.reply(toApplicationShouldTerminate: stop)
                }
            }
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            RecordingRuntime.shared.stop(); LibraryStore.shared.stop()
            TranscriptionQueue.shared.beginShutdown()
            SessionPlaybackController.stopAll(); RecordingController.shared.stop()
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated { urls.forEach { LegacyOpening.openDocument($0) } }
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { !CommandLine.arguments.contains("--recording-self-test") && !CommandLine.arguments.contains("--recording-sink-self-test") }

    @MainActor
    private static func handle(_ event: NSEvent) -> NSEvent? {
        guard event.modifierFlags.intersection([.command, .option, .control]).isEmpty,
              [49, 123, 124].contains(event.keyCode),
              let window = event.window else { return event }
        if window.attachedSheet != nil || NSApp.modalWindow != nil { return event }
        if let editor = window.firstResponder as? NSTextView, editor.isEditable {
            editor.keyDown(with: event)
            return nil
        }
        if window.accessibilityIdentifier() == "cassini-library-window", let detail = MeetingNavigation.shared.detail {
            switch event.keyCode {
            case 49: detail.toggle()
            case 123: detail.skip(-10)
            case 124: detail.skip(10)
            default: break
            }
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
