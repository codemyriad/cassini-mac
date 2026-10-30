// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit

/// Routes bare-key media shortcuts (Space, ←, →). The Playback menu lists them as key
/// equivalents so they are discoverable, but a bare key equivalent would steal typing from the
/// search field: this monitor runs first, hands the key to an editable text view when one has
/// focus, and otherwise acts on the key window's session, so the menu never sees those keys.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var monitor: Any?
    private var menuTrackingObservers: [NSObjectProtocol] = []
    @MainActor private static var trackingMenus: Set<ObjectIdentifier> = []
    private var confirmingQuit = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        ModelNotices.configureMenu()
        menuTrackingObservers = [NSMenu.didBeginTrackingNotification, NSMenu.didEndTrackingNotification].map { name in
            NotificationCenter.default.addObserver(forName:name,object:nil,queue:.main) { notification in
                MainActor.assumeIsolated {
                    guard let menu = notification.object as? NSMenu else { return }
                    if notification.name == NSMenu.didBeginTrackingNotification { Self.trackingMenus.insert(ObjectIdentifier(menu)) }
                    else { Self.trackingMenus.remove(ObjectIdentifier(menu)) }
                }
            }
        }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            MainActor.assumeIsolated { AppDelegate.handle(event) }
        }

        #if DEBUG
        if CommandLine.arguments.contains("--browser-background-self-test") {
            startBrowserConnection(root:BrowserBackgroundSelfTest.controlRoot)
            Task { @MainActor in await BrowserBackgroundSelfTest.run() }; return
        }
        if CommandLine.arguments.contains("--browser-capture-self-test") {
            Task { @MainActor in await CaptureSelfTest.run() }; return
        }
        if RecordingFixture.enabled { NSLog("Hosted recording fixture launch: %@", CommandLine.arguments) }
        if CommandLine.arguments.contains("--fixture-library-recording"), !RecordingFixture.enabled || RecordingFixture.root == nil {
            NSLog("Invalid hosted recording fixture: enabled=%d, root=%@, arguments=%@", RecordingFixture.enabled, String(describing: RecordingFixture.root), CommandLine.arguments)
            NSApp.terminate(nil); return
        }
        if CommandLine.arguments.contains("--recording-saving-self-test") {
            Task { @MainActor in await RecordingSavingSelfTest.run() }; return
        }
        if CommandLine.arguments.contains("--parakeet-self-test") {
            Task { @MainActor in await ParakeetSelfTest.run() }; return
        }
        if CommandLine.arguments.contains("--models-network-self-test") {
            Task { @MainActor in await ModelNetworkSelfTest.run() }; return
        }
        if CommandLine.arguments.contains("--recording-comfort-self-test") {
            Task { @MainActor in await RecordingComfortSelfTest.run() }; return
        }
        if CommandLine.arguments.contains("--trash-self-test") {
            Task { @MainActor in await TrashSelfTest.run() }; return
        }
        if CommandLine.arguments.contains("--import-lifecycle-self-test") {
            Task { @MainActor in await ImportLifecycleSelfTest.run() }; return
        }
        if CommandLine.arguments.contains("--settings-resume-moves-self-test") {
            Task { @MainActor in await SettingsSelfTest.resume() }; return
        }
        if CommandLine.arguments.contains("--settings-self-test") {
            Task { @MainActor in await SettingsSelfTest.run() }; return
        }
        if CommandLine.arguments.contains("--search-self-test") {
            Task { @MainActor in await SearchSelfTest.run() }; return
        }
        if ScreenshotFixture.launchIfRequested() {
            if RecordingFixture.enabled || RecordingPageFixture.enabled { RecordingRuntime.shared.start() }
            return
        }
        if CommandLine.arguments.contains("--export-self-test") {
            Task { @MainActor in await ExportSelfTest.run() }; return
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
        LibraryStore.shared.reloadLocation()
        LibraryMoveCoordinator.shared.start()
        CaptureNotifications.shared.configure()
        startBrowserConnection()
        ApplicationUpdates.shared.start()
    }

    @MainActor private func startBrowserConnection(root: URL? = nil) {
        Task { await CaptureCollection.shared.start(root:root) }
        CompanionSetup.shared.start()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !confirmingQuit else { return .terminateLater }
        if !RecordingConfirmation.active {
            let queue = TranscriptionQueue.shared
            let imports = LibraryImportCoordinator.shared
            let exports = MeetingExportCoordinator.shared
            let moves = LibraryMoveCoordinator.shared
            let wait = MeetingRenameCoordinator.shared.working || RecordingOverview.saving || queue.isBusy || imports.isBusy || exports.isBusy || moves.busy || MeetingTrashCoordinator.shared.busy || RecordingPageModel.hasPendingEdits
            CaptureCollection.shared.beginShutdown()
            imports.beginShutdown()
            MeetingRenameCoordinator.shared.beginShutdown()
            exports.beginShutdown()
            moves.beginShutdown()
            MeetingTrashCoordinator.shared.beginShutdown()
            queue.beginShutdown()
            guard wait else { return .terminateNow }
            confirmingQuit = true
            DispatchQueue.main.async { [weak self] in
                Task { @MainActor in
                    await RecordingPageModel.flushAll()
                    await RecordingController.shared.finishTask?.value
                    await CaptureCollection.shared.shutdown()
                    await queue.waitForShutdown()
                    await imports.waitForShutdown()
                    await MeetingRenameCoordinator.shared.waitForShutdown()
                    await exports.waitForShutdown()
                    await moves.waitForShutdown()
                    await MeetingTrashCoordinator.shared.waitForShutdown()
                    self?.confirmingQuit = false; sender.reply(toApplicationShouldTerminate:true)
                }
            }
            return .terminateLater
        }
        confirmingQuit = true
        DispatchQueue.main.async { [weak self] in
          Task { @MainActor in
            await MeetingRenameCoordinator.shared.dismissForQuit()
            await MeetingExportCoordinator.shared.dismissForQuit()
            await LibraryMoveCoordinator.shared.dismissForQuit()
            RecordingConfirmation.askToQuit(window: sender.keyWindow ?? sender.mainWindow) { choice in
                Task { @MainActor in
                    let stop = choice == .stop
                    if stop {
                        CaptureCollection.shared.beginShutdown()
                        LibraryMoveCoordinator.shared.beginShutdown()
                        MeetingTrashCoordinator.shared.beginShutdown()
                        MeetingRenameCoordinator.shared.beginShutdown()
                        MeetingExportCoordinator.shared.beginShutdown()
                        LibraryImportCoordinator.shared.beginShutdown()
                        TranscriptionQueue.shared.beginShutdown()
                        await RecordingConfirmation.stopAndWait()
                        await CaptureCollection.shared.shutdown()
                        await TranscriptionQueue.shared.waitForShutdown()
                        await LibraryImportCoordinator.shared.waitForShutdown()
                        await MeetingRenameCoordinator.shared.waitForShutdown()
                        await MeetingExportCoordinator.shared.waitForShutdown()
                        await LibraryMoveCoordinator.shared.waitForShutdown()
                        await MeetingTrashCoordinator.shared.waitForShutdown()
                    }
                    self?.confirmingQuit = false
                    sender.reply(toApplicationShouldTerminate: stop)
                    if choice == .background { DispatchQueue.main.async { RecordingConfirmation.closeWindowsKeepingRecording() } }
                }
            }
          }
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        menuTrackingObservers.forEach { NotificationCenter.default.removeObserver($0) }; menuTrackingObservers = []
        MainActor.assumeIsolated {
            Self.trackingMenus.removeAll()
            CompanionSetup.shared.stop()
            RecordingRuntime.shared.stop(); LibraryStore.shared.stop()
            TranscriptionQueue.shared.beginShutdown()
            LibraryImportCoordinator.shared.beginShutdown()
            MeetingRenameCoordinator.shared.beginShutdown()
            MeetingExportCoordinator.shared.beginShutdown()
            LibraryMoveCoordinator.shared.beginShutdown()
            MeetingTrashCoordinator.shared.beginShutdown()
            SessionPlaybackController.stopAll(); RecordingController.shared.stop()
            CaptureCollection.shared.beginShutdown()
        }
    }
    func applicationDidBecomeActive(_ notification: Notification) {
        MainActor.assumeIsolated { CaptureCollection.shared.retryFromSettings(); CompanionSetup.shared.trigger() }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated { urls.forEach { LegacyOpening.openDocument($0) } }
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { !CommandLine.arguments.contains("--recording-self-test") && !CommandLine.arguments.contains("--recording-sink-self-test") }

    @MainActor
    private static func handle(_ event: NSEvent) -> NSEvent? {
        // AppKit's outline consumes Return before SwiftUI onKeyPress. Treat it
        // as the Library selection's primary action, like the native row's
        // double-click; menus and editors keep their own Return behavior.
        if [36,76].contains(event.keyCode),
           event.modifierFlags.intersection([.command,.option,.control,.shift]).isEmpty,
           trackingMenus.isEmpty,
           let window = event.window ?? NSApp.keyWindow,
           window.accessibilityIdentifier() == "cassini-library-window",
           window.attachedSheet == nil, NSApp.modalWindow == nil,
           !(window.firstResponder is NSText), MeetingNavigation.shared.detail == nil,
           !MeetingNavigation.shared.loading, !LibrarySearchModel.shared.visible,
           !LibraryMoveCoordinator.shared.busy, let meeting = LibraryStore.shared.selected {
            SessionPlaybackController.stopAll(); MeetingNavigation.shared.open(meeting)
            return nil
        }
        if let window = event.window ?? NSApp.keyWindow,
           window.accessibilityIdentifier() == "cassini-library-window",
           window.attachedSheet == nil, NSApp.modalWindow == nil,
           !(window.firstResponder is NSText), MeetingNavigation.shared.detail == nil,
           !MeetingNavigation.shared.loading, !LibrarySearchModel.shared.visible,
           event.modifierFlags.intersection([.command,.option,.control]).isEmpty,
           ((event.keyCode == 109 && event.modifierFlags.contains(.shift)) || event.charactersIgnoringModifiers == "\u{F735}"),
           let meeting = LibraryStore.shared.selected,
           LibraryKeyboardMenu.show(meeting,trash:MeetingTrashCoordinator.shared,undo:window.undoManager) { return nil }
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
