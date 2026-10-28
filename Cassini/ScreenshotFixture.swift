// SPDX-License-Identifier: GPL-3.0-or-later
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
              ["window", "sheet", "library", "first-run", "meeting", "record-first", "recording", "received", "export", "search"].contains(name),
              let directory = value("-CassiniFixture", in: arguments),
              let clock = value("-CassiniNow", in: arguments),
              ISO8601DateFormatter().date(from: clock) != nil else {
            NSLog("Invalid or non-hosted screenshot invocation")
            NSApp.terminate(nil)
            return true
        }
        // LibraryLaunchContext consumes the validated frozen clock for Library
        // boards; the legacy document capture has no wall-clock labels.
        let fixture = URL(fileURLWithPath: directory, isDirectory: true)
            .appendingPathComponent("meeting.opus")
        if let path = value("-CassiniOpenFile", in: arguments) { LegacyOpening.openDocument(URL(fileURLWithPath: path)) }
        if name == "window" || name == "sheet" {
            Task { @MainActor in
                for _ in 0..<100 {
                    if let open = LegacyOpening.handler { open(fixture); return }
                    try? await Task.sleep(for: .milliseconds(100))
                }
                NSApp.terminate(nil)
            }
        }

        return true
    }

    private static func value(_ key: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: key), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }

    private static var prepared = Set<ObjectIdentifier>()
    static func prepareLibrary(_ window: NSWindow) {
        guard ["library", "first-run", "meeting", "record-first", "recording", "received", "export", "search"].contains(LibraryLaunchContext.argument("-CassiniScreenshot") ?? ""),
              ProcessInfo.processInfo.environment["CASSINI_HOSTED_SCREENSHOTS"] == "1" else { return }
        guard prepared.insert(ObjectIdentifier(window)).inserted else { return }
        prepare(window, sheet: false, boardSize: true)
        window.setAccessibilityIdentifier("cassini-library-window")
        localBoardRender(window)
    }
    /// Explicit local workflow fallback for a locked console without XCTest
    /// automation. Renders only this app's fixture view, never the desktop.
    private static func localBoardRender(_ window: NSWindow) {
        guard ProcessInfo.processInfo.environment["CASSINI_LOCAL_WORKFLOW_TESTS"] == "1",
              let name = LibraryLaunchContext.argument("-CassiniScreenshot"), ["recording","received","export","search"].contains(name),
              !RecordingFixture.enabled else { return }
        Task { @MainActor in
            for _ in 0..<60 {
                if name == "recording" && MeetingNavigation.shared.detail?.meeting.state.lifecycle == .recording { break }
                if name == "received" && LibraryStore.shared.selected?.state.origin == .received { break }
                if name == "export" && window.attachedSheet != nil { break }
                if name == "search" && LibrarySearchModel.shared.hits.count == 4 { break }
                try? await Task.sleep(for:.milliseconds(100))
            }
            try? await Task.sleep(for:.seconds(1))
            guard (name != "recording" || MeetingNavigation.shared.detail?.meeting.state.lifecycle == .recording),
                  (name != "export" || window.attachedSheet != nil),
                  (name != "search" || LibrarySearchModel.shared.hits.count == 4),
                  window.frame.size == NSSize(width:1120,height:720),
                  let frame = window.contentView?.superview,
                  let image = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:1120,pixelsHigh:720,
                    bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0) else { exit(1) }
            image.size = NSSize(width:1120,height:720)
            frame.layoutSubtreeIfNeeded(); frame.cacheDisplay(in:frame.bounds,to:image)
            if let sheet = window.attachedSheet, let view = sheet.contentView?.superview,
               let overlay = view.bitmapImageRepForCachingDisplay(in:view.bounds) {
                view.layoutSubtreeIfNeeded(); view.cacheDisplay(in:view.bounds,to:overlay)
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep:image)
                let sheetImage = NSImage(size:view.bounds.size); sheetImage.addRepresentation(overlay)
                sheetImage.draw(in:NSRect(x:sheet.frame.minX - window.frame.minX,
                    y:sheet.frame.minY - window.frame.minY,width:sheet.frame.width,height:sheet.frame.height))
                NSGraphicsContext.restoreGraphicsState()
            }
            guard let png = image.representation(using:.png,properties:[:]),
                  let output = try? JSONSerialization.data(withJSONObject:["board":name,"pngBase64":png.base64EncodedString()]) else { exit(1) }
            FileHandle.standardOutput.write(output + Data([10])); exit(0)
        }
    }
    static func prepareLegacy(_ window: NSWindow) {
        guard let name = LibraryLaunchContext.argument("-CassiniScreenshot"), ["window", "sheet"].contains(name),
              ProcessInfo.processInfo.environment["CASSINI_HOSTED_SCREENSHOTS"] == "1" else { return }
        guard prepared.insert(ObjectIdentifier(window)).inserted else { return }
        prepare(window, sheet: name == "sheet", boardSize: LibraryLaunchContext.argument("-CassiniScreenshotSize") == "1120x720")
    }
    private static func prepare(_ window: NSWindow, sheet: Bool, boardSize: Bool) {
        window.setAccessibilityIdentifier("cassini-screenshot-window")
        window.toolbarStyle = .unified
        guard let screen = window.screen ?? NSScreen.main else { NSApp.terminate(nil); return }
        // The board-size job selects a larger display mode before launch. Keep
        // every edge on screen; never pass by clipping an offscreen window.
        let frame = NSRect(x: screen.visibleFrame.minX + 24, y: screen.visibleFrame.minY + 16,
                           width: boardSize ? 1120 : 960, height: boardSize ? 720 : 640)
        guard screen.visibleFrame.contains(frame) else { NSApp.terminate(nil); return }
        window.setFrame(frame, display: true)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if sheet {
            // HARMONY §7 confirmation 1. This presents the native sheet for the
            // capture spike only; it does not implement recording-close behavior.
            let alert = NSAlert()
            alert.messageText = "A recording is running"
            alert.informativeText = "Stop and keep it, or keep recording in the background?"
            alert.addButton(withTitle: "Stop and keep it").keyEquivalent = "\r"
            alert.addButton(withTitle: "Keep recording").keyEquivalent = "\u{1B}"
            alert.beginSheetModal(for: window) { response in
                // Expose only the fixture result to the keyboard regression tests.
                // Neither action starts or stops a real recording.
                window.setAccessibilityIdentifier(response == .alertFirstButtonReturn
                    ? "cassini-screenshot-stopped" : "cassini-screenshot-kept")
            }
        }
    }
}
#endif
