// SPDX-License-Identifier: GPL-3.0-or-later
#if DEBUG
import AppKit

/// Fixture-only entry point. Never starts capture or playback. Enabled solely by the
/// hosted screenshot test's launch environment, and absent from release builds.
@MainActor
enum ScreenshotFixture {
    /// A long sealed input is copied and extended by the app inside its own
    /// sandbox. The UI runner cannot write another app's container.
    static let longMeetingDirectory: URL? = {
        guard ProcessInfo.processInfo.environment["CASSINI_HOSTED_SCREENSHOTS"] == "1",
              LibraryLaunchContext.argument("-CassiniScreenshot") == "library",
              LibraryLaunchContext.argument("-CassiniLongMeetingFixture") == "YES" else { return nil }
        let source = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/Fixtures/Library/main")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CassiniLongMeeting-" + UUID().uuidString)
        do {
            try FileManager.default.copyItem(at: source, to: directory)
            let file = directory.appendingPathComponent("root/Recording-a0000000-0000-4000-8000-000000000001/transcript.json")
            var body = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String:Any]
            var items = body["items"] as! [[String:Any]]
            for index in 0..<30 {
                items.append(["speaker":["marta","dario","guest"][index % 3],"startMs":1_000_000 + index * 30_000,
                              "endMs":1_008_000 + index * 30_000,
                              "text":"We will review this decision with the team and keep the updated figures in the meeting notes."])
            }
            body["items"] = items
            try JSONSerialization.data(withJSONObject: body).write(to: file, options: .atomic)
            return directory
        } catch { preconditionFailure("Cannot prepare long meeting screenshot fixture: \(error)") }
    }()
    static func launchIfRequested() -> Bool {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("-CassiniScreenshot") else { return false }
        let scheme = value("-CassiniScreenshotScheme", in: arguments) ?? "light"
        guard ProcessInfo.processInfo.environment["CASSINI_HOSTED_SCREENSHOTS"] == "1",
              let name = value("-CassiniScreenshot", in: arguments),
              ["window", "sheet", "library", "first-run", "meeting", "record-first", "recording", "received", "export", "search", "settings-recording", "settings-transcription", "settings-library", "settings-browser"].contains(name),
              ["light", "dark"].contains(scheme),
              let directory = value("-CassiniFixture", in: arguments),
              let clock = value("-CassiniNow", in: arguments),
              ISO8601DateFormatter().date(from: clock) != nil else {
            NSLog("Invalid or non-hosted screenshot invocation")
            NSApp.terminate(nil)
            return true
        }
        if scheme == "dark" {
            NSApp.appearance = NSAppearance(named: .darkAqua)
        }
        // LibraryLaunchContext consumes the validated frozen clock for Library
        // boards; the legacy document capture has no wall-clock labels.
        let fixture = URL(fileURLWithPath: directory, isDirectory: true)
            .appendingPathComponent("meeting.opus")
        if let path = value("-CassiniOpenFile", in: arguments) { LegacyOpening.openDocument(URL(fileURLWithPath: path)) }
        if name == "window" || name == "sheet" {
            Task { @MainActor in
                // The normal facade dispatches now or retains the request until
                // its handler is installed. No timed startup polling is needed.
                LegacyOpening.openDocument(fixture)
            }
        }

        if name.hasPrefix("settings-") {
            Task { @MainActor in
                SettingsNavigation.shared.tab = SettingsTab(rawValue:String(name.dropFirst("settings-".count))) ?? .recording
                ApplicationWindows.preferences()
                NSApp.activate(ignoringOtherApps: true)
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
              let name = LibraryLaunchContext.argument("-CassiniScreenshot"), ["first-run","meeting","recording","received","export","search"].contains(name),
              !RecordingFixture.enabled else { return }
        Task { @MainActor in
            for _ in 0..<60 {
                if name == "first-run" && LibraryStore.shared.loaded { break }
                if name == "meeting" && MeetingNavigation.shared.detail != nil { break }
                if name == "recording" && MeetingNavigation.shared.detail?.meeting.state.lifecycle == .recording { break }
                if name == "received" && LibraryStore.shared.selected?.state.origin == .received { break }
                if name == "export" && window.attachedSheet != nil { break }
                if name == "search" && LibrarySearchModel.shared.hits.count == 4 { break }
                try? await Task.sleep(for:.milliseconds(100))
            }
            if name == "meeting", CommandLine.arguments.contains("--speaker-editor-preview"),
               let meeting=MeetingNavigation.shared.detail?.meeting {
                await MeetingRenameCoordinator.shared.previewSpeaker(meeting)
            }
            try? await Task.sleep(for:.seconds(1))
            guard (name != "first-run" || LibraryStore.shared.loaded && LibraryStore.shared.meetings.isEmpty),
                  (name != "recording" || MeetingNavigation.shared.detail?.meeting.state.lifecycle == .recording),
                  (name != "meeting" || MeetingNavigation.shared.detail != nil),
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
        if LibraryLaunchContext.screenshotDark { window.appearance = NSAppearance(named: .darkAqua) }
        window.setAccessibilityIdentifier("cassini-screenshot-window")
        ScrollEdgeChrome.configureUnifiedWindow(window)
        guard let screen = window.screen ?? NSScreen.main else { NSApp.terminate(nil); return }
        // The board-size job selects a larger display mode before launch. Keep
        // every edge on screen; never pass by clipping an offscreen window.
        let shortSpeakerWindow = LibraryLaunchContext.argument("-CassiniScreenshotSize") == "760x480"
        let frame = NSRect(x: screen.visibleFrame.minX + 24, y: screen.visibleFrame.minY + 16,
                           width: shortSpeakerWindow ? 760 : boardSize ? 1120 : 960, height: shortSpeakerWindow ? 480 : boardSize ? 720 : 640)
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
