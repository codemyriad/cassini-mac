// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit

@MainActor enum RecordingConfirmation {
    private static var delegates: [ObjectIdentifier: CloseDelegate] = [:]
    static var active: Bool {
        #if DEBUG
        if ProcessInfo.processInfo.environment["CASSINI_HOSTED_SCREENSHOTS"] == "1", CommandLine.arguments.contains("--fixture-recording-active") { return !fixtureStopped }
        #endif
        return RecordingController.shared.isRecording || RecordingController.shared.isStarting
    }
    #if DEBUG
    private static var fixtureStopped = false
    #endif
    static func stop() {
        #if DEBUG
        fixtureStopped = true
        #endif
        RecordingController.shared.stop()
    }
    static func stopAndWait() async {
        stop(); await RecordingPageModel.flushAll(); await RecordingController.shared.finishTask?.value
    }
    static func ask(window: NSWindow?, completion: @escaping (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = UXText.text("confirm.recordingRunning.title")
        alert.informativeText = UXText.text("confirm.recordingRunning.body")
        alert.addButton(withTitle: UXText.text("confirm.recordingRunning.primary")).keyEquivalent = "\r"
        alert.addButton(withTitle: UXText.text("confirm.recordingRunning.secondary")).keyEquivalent = "\u{1B}"
        if let window { alert.beginSheetModal(for: window) { completion($0 == .alertFirstButtonReturn) } }
        else { completion(alert.runModal() == .alertFirstButtonReturn) }
    }
    static func attach(to window: NSWindow) {
        let id = ObjectIdentifier(window)
        if window.delegate is CloseDelegate { return }
        let proxy = CloseDelegate(window: window)
        delegates[id] = proxy; window.delegate = proxy
    }
    private final class CloseDelegate: NSObject, NSWindowDelegate {
        weak var window: NSWindow?
        weak var original: (any NSWindowDelegate)?
        private var approved = false
        private var asking = false
        @MainActor init(window: NSWindow) { self.window = window; original = window.delegate }
        override func responds(to selector: Selector!) -> Bool { super.responds(to: selector) || original?.responds(to: selector) == true }
        override func forwardingTarget(for selector: Selector!) -> Any? { original?.responds(to: selector) == true ? original : super.forwardingTarget(for: selector) }
        func windowShouldClose(_ sender: NSWindow) -> Bool {
            if approved { approved = false; return original?.windowShouldClose?(sender) ?? true }
            guard RecordingConfirmation.active else { return original?.windowShouldClose?(sender) ?? true }
            guard !asking else { return false }; asking = true
            RecordingConfirmation.ask(window: sender) { [weak self, weak sender] stop in
                guard let self, let sender else { return }
                Task { @MainActor in
                    guard stop else { self.asking = false; return }
                    await RecordingConfirmation.stopAndWait()
                    self.asking = false; self.approved = true
                    // Finish saving and let AppKit detach the sheet before close.
                    DispatchQueue.main.async { sender.performClose(nil) }
                }
            }
            return false
        }
        func windowWillClose(_ notification: Notification) {
            original?.windowWillClose?(notification)
            guard let window else { return }
            DispatchQueue.main.async { [self] in
                guard !window.isVisible else { return }
                if window.delegate === self { window.delegate = original }
                let id = ObjectIdentifier(window)
                if RecordingConfirmation.delegates[id] === self { RecordingConfirmation.delegates.removeValue(forKey: id) }
            }
        }
    }
}
