#if DEBUG
import AppKit

/// Fixture-only entry point. Never starts capture or playback. Enabled solely by the
/// hosted screenshot test's launch environment, and absent from release builds.
@MainActor
enum ScreenshotFixture {
    static func launchIfRequested() -> Bool {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("-CassiniScreenshot") else { return false }
        guard ProcessInfo.processInfo.environment["CASSINI_HOSTED_SCREENSHOTS"] == "1",
              let name = value("-CassiniScreenshot", in: arguments),
              ["window", "sheet"].contains(name),
              let directory = value("-CassiniFixture", in: arguments),
              let clock = value("-CassiniNow", in: arguments),
              ISO8601DateFormatter().date(from: clock) != nil else {
            NSLog("Invalid or non-hosted screenshot invocation")
            NSApp.terminate(nil)
            return true
        }
        // Validate the frozen-clock contract now; the current document UI has no
        // wall-clock labels. A later Library fixture renderer will consume it.
        let fixture = URL(fileURLWithPath: directory, isDirectory: true)
            .appendingPathComponent("meeting.opus")
        NSDocumentController.shared.openDocument(withContentsOf: fixture, display: true) { document, _, error in
            Task { @MainActor in
                guard error == nil, let document else {
                    NSLog("Screenshot fixture could not open: %@", String(describing: error))
                    NSApp.terminate(nil)
                    return
                }
                // SwiftUI creates its window asynchronously after opening the document.
                for _ in 0..<100 {
                    if let window = document.windowControllers.compactMap(\.window).first {
                        prepare(window, sheet: name == "sheet")
                        return
                    }
                    try? await Task.sleep(for: .milliseconds(100))
                }
                NSLog("Screenshot document did not create a window")
                NSApp.terminate(nil)
            }
        }
        return true
    }

    private static func value(_ key: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: key), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }

    private static func prepare(_ window: NSWindow, sheet: Bool) {
        window.setAccessibilityIdentifier("cassini-screenshot-window")
        window.toolbarStyle = .unified
        window.setFrame(NSRect(x: 80, y: 80, width: 1120, height: 720), display: true)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if sheet {
            // HARMONY §7 confirmation 1. This presents the native sheet for the
            // capture spike only; it does not implement recording-close behavior.
            let alert = NSAlert()
            alert.messageText = "A recording is running"
            alert.informativeText = "Stop and keep it, or keep recording in the background?"
            alert.addButton(withTitle: "Keep recording")
            alert.addButton(withTitle: "Stop and keep it")
            alert.beginSheetModal(for: window)
        }
    }
}
#endif
