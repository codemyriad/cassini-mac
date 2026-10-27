// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import XCTest

final class LibraryBoards: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        try XCTSkipUnless(ProcessInfo.processInfo.environment["CASSINI_HOSTED_SCREENSHOTS"] == "1" && ProcessInfo.processInfo.environment["CASSINI_LIBRARY_BOARDS"] == "1", "Hosted-only Library boards")
    }
    @MainActor func testLibrary() throws { try board("library", fixture: "main") }
    @MainActor func testFirstRun() throws { try board("first-run", fixture: "empty") }
    @MainActor func testRecordFirstBoard() throws {
        let app = try launch("record-first", fixture: "first-record"); defer { app.terminate() }
        let window = app.windows["cassini-library-window"]
        XCTAssertTrue(window.sheets.staticTexts["Before your first recording"].waitForExistence(timeout: 20), app.debugDescription)
        XCTAssertTrue(window.sheets.checkBoxes["Don’t show again"].exists)
        XCTAssertTrue(window.sheets.buttons["record-first-start"].exists)
        XCTAssertTrue(text("macOS asks you to allow this next.", in: window.sheets.firstMatch))
        XCTAssertTrue(text("macOS asks once more, for Screen & System Audio Recording.", in: window.sheets.firstMatch))
        let explanation = window.sheets.staticTexts["Cassini also records the sound of your meeting apps so the other participants are on the recording."]
        XCTAssertTrue(explanation.exists)
        XCTAssertGreaterThan(explanation.frame.height, 28, "The complete explanation must wrap, rather than truncate")
        capture(window, name: "record-first")
        XCTAssertEqual(window.frame.width, 1120, accuracy: 0.1)
        XCTAssertEqual(window.frame.height, 720, accuracy: 0.1)
        window.sheets.buttons["Not now"].click()
        XCTAssertFalse(window.buttons["recording-stop"].exists)
    }
    @MainActor func testCaptureWritesIntoLibraryAndSaves() throws {
        let id = UUID().uuidString
        let app = try launch("first-run", fixture: "empty", extra: ["--fixture-library-recording", "-CassiniCaptureID", id])
        defer { app.terminate() }
        let window = app.windows["cassini-library-window"]
        XCTAssertTrue(window.buttons["first-run-record"].waitForExistence(timeout: 20), app.debugDescription)
        window.buttons["first-run-record"].click()
        XCTAssertTrue(window.sheets.buttons["record-first-start"].waitForExistence(timeout: 10))
        window.sheets.buttons["record-first-start"].click()
        XCTAssertTrue(window.buttons["recording-stop"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(app.windows.count, 1)
        XCTAssertFalse(app.windows["open-panel"].exists)
        let mic = window.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Your microphone")).firstMatch
        let meterReady = NSPredicate { _, _ in (mic.value as? String) == "12" }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: meterReady, object: nil)], timeout: 5), .completed, window.debugDescription)
        window.buttons["recording-stop"].click()
        XCTAssertTrue(window.staticTexts["Saving…"].waitForExistence(timeout: 5), window.debugDescription)
        let saved = NSPredicate { _, _ in window.buttons["preview-play"].exists && window.buttons["preview-play"].isEnabled && !window.staticTexts["Saving…"].exists }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: saved, object: nil)], timeout: 10), .completed, window.debugDescription)
        XCTAssertFalse(window.buttons["recording-stop"].exists)
        XCTAssertFalse(app.windows["open-panel"].exists)
    }
    @MainActor func testRecordFirstPreferenceSurvivesRelaunch() throws {
        let extra = ["--fixture-library-recording", "-CassiniCaptureID", UUID().uuidString]
        var app = try launch("first-run", fixture: "empty", extra: extra)
        defer { if app.state != .notRunning { app.terminate() } }
        var window = app.windows["cassini-library-window"]
        XCTAssertTrue(window.buttons["first-run-record"].waitForExistence(timeout: 20))
        window.buttons["first-run-record"].click()
        let checkbox = window.sheets.checkBoxes["Don’t show again"]
        XCTAssertTrue(checkbox.waitForExistence(timeout: 10)); checkbox.click()
        window.sheets.buttons["Not now"].click()
        app.terminate()
        app = try launch("first-run", fixture: "empty", extra: extra)
        window = app.windows["cassini-library-window"]
        XCTAssertTrue(window.buttons["first-run-record"].waitForExistence(timeout: 20))
        app.typeKey("r", modifierFlags: .command)
        XCTAssertTrue(window.buttons["recording-stop"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertFalse(window.sheets.firstMatch.exists)
        app.typeKey("r", modifierFlags: .command)
        let saved = NSPredicate { _, _ in window.buttons["preview-play"].exists && window.buttons["preview-play"].isEnabled && !window.staticTexts["Saving…"].exists }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: saved, object: nil)], timeout: 10), .completed)
    }
    @MainActor func testDiskReserveStopsAndKeepsTheRecording() throws {
        let extra = ["--fixture-library-recording", "-CassiniCaptureID", UUID().uuidString,
                     "-CassiniDiskFree", "1073741824", "-CassiniDiskTotal", "10000000000"]
        let app = try launch("first-run", fixture: "empty", extra: extra); defer { app.terminate() }
        let window = app.windows["cassini-library-window"]
        XCTAssertTrue(window.buttons["first-run-record"].waitForExistence(timeout: 20), app.debugDescription)
        window.buttons["first-run-record"].click()
        XCTAssertTrue(window.sheets.staticTexts["Only 0 minutes of space left."].waitForExistence(timeout: 10))
        XCTAssertFalse(window.sheets.buttons["Choose another folder"].exists)
        window.sheets.buttons["record-first-start"].click()
        let line = "Cassini stopped recording to keep some space free on this computer. Everything up to now is saved."
        XCTAssertTrue(window.staticTexts[line].waitForExistence(timeout: 10), app.debugDescription)
        let saved = NSPredicate { _, _ in window.buttons["preview-play"].exists && window.buttons["preview-play"].isEnabled && !window.staticTexts["Saving…"].exists }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: saved, object: nil)], timeout: 10), .completed)
        XCTAssertFalse(window.buttons["recording-stop"].exists)
    }
    @MainActor func testMeetingBoard() throws {
        let app = try launch("meeting", fixture: "main"); defer { app.terminate() }
        let window = app.windows["cassini-library-window"]
        XCTAssertTrue(window.buttons["meeting-back"].waitForExistence(timeout: 20), app.debugDescription)
        XCTAssertTrue(window.staticTexts["meeting-elapsed"].waitForExistence(timeout: 10))
        let title = window.staticTexts["meeting-title"]
        XCTAssertTrue(title.waitForExistence(timeout: 5), window.debugDescription)
        XCTAssertTrue(title.isHittable, window.debugDescription)
        XCTAssertTrue(text("Client call, Rossi & Partners", in: window))
        XCTAssertTrue(text("Today, 11:30 · 47 min", in: window))
        XCTAssertEqual(title.frame.minX - window.frame.minX, 280, accuracy: 16)
        capture(window, name: "meeting")
        for value in ["43%", "36%", "21%", "00:03:12", "00:47:05", "Named by you", "Recognised from saved voices", "Not named yet"] { XCTAssertTrue(text(value, in: window), value) }
        XCTAssertFalse(window.buttons["Name the speakers"].exists)
        XCTAssertFalse(window.buttons["Inspector"].exists)
        XCTAssertEqual(window.frame.width, 1120, accuracy: 0.1)
        XCTAssertEqual(window.frame.height, 720, accuracy: 0.1)
        window.buttons["Forward 10 seconds"].click()
        XCTAssertTrue(text("00:03:22", in: window))
        window.buttons["Back 10 seconds"].click()
        XCTAssertTrue(text("00:03:12", in: window))
    }
    @MainActor func testTranscriptCanBeClosedAndReopened() throws {
        let app = try launch("library", fixture: "main"); defer { app.terminate() }
        let library = app.windows["cassini-library-window"]
        for _ in 0..<3 {
            let read = library.buttons["preview-read-transcript"]
            XCTAssertTrue(read.waitForExistence(timeout: 20)); read.click()
            XCTAssertTrue(library.buttons["meeting-back"].waitForExistence(timeout: 10))
            XCTAssertEqual(app.windows.count, 1)
            library.buttons["meeting-back"].click()
            XCTAssertTrue(read.waitForExistence(timeout: 10))
        }
    }
    @MainActor func testOpenAndFinderRoutingWithLibraryClosed() async throws {
        let app = try launch("first-run", fixture: "empty"); defer { app.terminate() }
        let library = app.windows["cassini-library-window"]
        XCTAssertTrue(library.waitForExistence(timeout: 20))
        library.buttons["_XCUI:CloseWindow"].click()
        let closed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: library)
        XCTAssertEqual(XCTWaiter.wait(for: [closed], timeout: 5), .completed)
        app.typeKey("o", modifierFlags: .command)
        XCTAssertTrue(app.windows["open-panel"].waitForExistence(timeout: 5), app.debugDescription)
        app.typeKey(.escape, modifierFlags: [])
        let cancelled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.windows["open-panel"])
        XCTAssertEqual(XCTWaiter.wait(for: [cancelled], timeout: 5), .completed)
        XCTAssertFalse(library.exists)
        let fixture = try fixtureDirectory().appendingPathComponent("meeting.opus")
        for _ in 0..<2 {
            try await finderOpen(fixture)
            XCTAssertTrue(library.buttons["meeting-back"].waitForExistence(timeout: 15), app.debugDescription)
            XCTAssertEqual(app.windows.count, 1)
        }
        library.buttons["_XCUI:CloseWindow"].click()
        let closedAgain = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: library)
        XCTAssertEqual(XCTWaiter.wait(for: [closedAgain], timeout: 5), .completed)
        try await finderOpen(fixture)
        XCTAssertTrue(library.buttons["meeting-back"].waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertEqual(app.windows.count, 1)
    }
    @MainActor func testReceivedReadAndPlayReuseOneViewer() throws {
        let app = try launch("library", fixture: "main"); defer { app.terminate() }
        let library = app.windows["cassini-library-window"]
        let received = library.descendants(matching: .any).matching(identifier: "meeting-Received-a0000000-0000-4000-8000-000000000006").firstMatch
        XCTAssertTrue(received.waitForExistence(timeout: 20), app.debugDescription)
        received.click(); library.buttons["preview-read-transcript"].click()
        XCTAssertTrue(library.buttons["meeting-back"].waitForExistence(timeout: 15))
        XCTAssertEqual(app.windows.count, 1)
        library.buttons["meeting-back"].click()
        XCTAssertTrue(library.buttons["preview-play"].waitForExistence(timeout: 10))
        library.buttons["preview-play"].click()
        XCTAssertTrue(library.buttons["meeting-back"].waitForExistence(timeout: 15))
        XCTAssertEqual(app.windows.count, 1)
    }
    @MainActor func testSuggestionDismissalPersistsAcrossNavigation() throws {
        let app = try launch("library", fixture: "main"); defer { app.terminate() }
        let window = app.windows["cassini-library-window"]
        XCTAssertTrue(window.buttons["preview-read-transcript"].waitForExistence(timeout: 20))
        window.buttons["preview-read-transcript"].click()
        XCTAssertTrue(window.buttons["Not now"].waitForExistence(timeout: 10))
        window.buttons["Not now"].click()
        window.buttons["meeting-back"].click()
        window.buttons["preview-read-transcript"].click()
        XCTAssertFalse(window.buttons["Not now"].exists)
    }
    @MainActor func testCloseAndQuitConfirmationKeyboardRoles() throws {
        let app = try launch("first-run", fixture: "empty", extra: ["--fixture-recording-active"])
        defer { if app.state != .notRunning { app.terminate() } }
        let window = app.windows["cassini-library-window"]
        XCTAssertTrue(window.waitForExistence(timeout: 20))
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(window.sheets.staticTexts["A recording is running"].waitForExistence(timeout: 10))
        app.typeKey(.escape, modifierFlags: [])
        let closed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: window)
        XCTAssertEqual(XCTWaiter.wait(for: [closed], timeout: 10), .completed)
        app.typeKey("q", modifierFlags: .command)
        XCTAssertTrue(app.staticTexts["A recording is running"].waitForExistence(timeout: 10))
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(app.state != .notRunning)
        app.typeKey("q", modifierFlags: .command)
        XCTAssertTrue(app.staticTexts["A recording is running"].waitForExistence(timeout: 10))
        app.typeKey(.return, modifierFlags: [])
        let ended = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in app.state == .notRunning }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [ended], timeout: 10), .completed)
    }
    @MainActor func testFailedReadClosesLoadingViewer() throws {
        let app = XCUIApplication(); defer { app.terminate() }
        app.launchEnvironment["CASSINI_HOSTED_SCREENSHOTS"] = "1"
        // Legacy fixture routing intentionally points to a nonexistent file.
        // That mode skips the real Library scanner and never starts playback.
        let absent = try fixtureDirectory().appendingPathComponent("absent-fixture")
        app.launchArguments = ["-CassiniScreenshot", "first-run", "-CassiniFixture", try fixtureDirectory().appendingPathComponent("Library/empty").path, "-CassiniOpenFile", absent.appendingPathComponent("meeting.opus").path,
                               "-CassiniNow", "2026-10-27T13:18:00Z", "-ApplePersistenceIgnoreState", "YES",
                               "-AppleLanguages", "(en-GB)", "-AppleLocale", "en_GB"]
        app.launch()
        let okay = app.dialogs.firstMatch.buttons["OK"]
        XCTAssertTrue(okay.waitForExistence(timeout: 15), app.debugDescription)
        okay.click()
        let settled = NSPredicate { _, _ in app.progressIndicators.count == 0 && app.windows.count == 1 }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: settled, object: nil)], timeout: 10), .completed, app.debugDescription)
        XCTAssertTrue(app.windows["cassini-library-window"].exists)
    }
    @MainActor private func finderOpen(_ url: URL) async throws {
        let appURL = try fixtureDirectory().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        XCTAssertEqual(appURL.pathExtension, "app")
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        _ = try await NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: configuration)
    }
    @MainActor private func launch(_ name: String, fixture: String, extra: [String] = []) throws -> XCUIApplication {
        let app = XCUIApplication()
        let root = try fixtureDirectory().appendingPathComponent("Library/" + fixture)
        app.launchEnvironment["CASSINI_HOSTED_SCREENSHOTS"] = "1"
        app.launchArguments = ["-CassiniScreenshot", name, "-CassiniFixture", root.path,
                               "-CassiniNow", "2026-10-27T13:18:00Z", "-ApplePersistenceIgnoreState", "YES",
                               "-AppleLanguages", "(en-GB)", "-AppleLocale", "en_GB", "-AppleInterfaceStyle", "Light", "-AppleAccentColor", "4"]
        app.launchArguments += extra
        app.launch()
        if extra.contains("--fixture-library-recording"), !app.windows.firstMatch.waitForExistence(timeout: 2) {
            app.menuBars.menuBarItems["Window"].click()
            app.menuBars.menuBarItems["Window"].menus.menuItems["Library"].click()
        }
        return app
    }
    @MainActor private func board(_ name: String, fixture: String) throws {
        let app = try launch(name, fixture: fixture); defer { app.terminate() }
        let window = app.windows["cassini-library-window"]
        XCTAssertTrue(window.waitForExistence(timeout: 20), app.debugDescription)
        let expectedControl = name == "library" ? "preview-read-transcript" : "first-run-record"
        XCTAssertTrue(window.buttons[expectedControl].waitForExistence(timeout: 20), window.debugDescription)
        let exactFrame = NSPredicate { _, _ in abs(window.frame.width - 1120) < 0.1 && abs(window.frame.height - 720) < 0.1 }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: exactFrame, object: nil)], timeout: 10), .completed, window.debugDescription)
        if name == "library" {
            let subtitle = window.staticTexts["preview-subtitle"]
            let ready = NSPredicate { _, _ in subtitle.exists && subtitle.isHittable && subtitle.frame.minX >= window.frame.minX + 420 }
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: ready, object: nil)], timeout: 10), .completed, window.debugDescription)
            capture(window, name: name)
            XCTAssertTrue(window.buttons["preview-read-transcript"].waitForExistence(timeout: 20), window.debugDescription)
            XCTAssertTrue(window.staticTexts.matching(NSPredicate(format: "value CONTAINS %@ OR label CONTAINS %@", "52 min · Marta, Dario, Speaker 3", "52 min · Marta, Dario, Speaker 3")).firstMatch.exists)
            XCTAssertTrue(text("Today, 09:00 · 52 min", in: window), window.debugDescription)
            XCTAssertTrue(text("00:00:04", in: window))
            XCTAssertTrue(text("Listening inside your browser", in: window))
            XCTAssertTrue(text("Your microphone and the meeting in your browser", in: window))
            XCTAssertTrue(window.buttons["preview-play"].isEnabled)
            let title = window.staticTexts["library-toolbar-title"]
            XCTAssertTrue(title.exists)
            XCTAssertEqual(title.frame.minX - window.frame.minX, 420, accuracy: 12)
        } else {
            capture(window, name: name)
            XCTAssertTrue(window.buttons["first-run-record"].waitForExistence(timeout: 20), window.debugDescription)
            XCTAssertTrue(text("Your recorded meetings will appear here.", in: window))
            XCTAssertTrue(text("Recordings and transcripts stay on this computer, in Music/Cassini.", in: window))
            let title = window.staticTexts["library-toolbar-title"]
            XCTAssertTrue(title.exists)
            XCTAssertEqual(title.frame.midX, window.frame.midX, accuracy: 20)
        }
        XCTAssertEqual(window.frame.width, 1120, accuracy: 0.1)
        XCTAssertEqual(window.frame.height, 720, accuracy: 0.1)
    }
    private func capture(_ window: XCUIElement, name: String) {
        // Retain an exact-size, fully laid-out board even if a content check fails.
        let attachment = XCTAttachment(screenshot: window.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    private func text(_ value: String, in window: XCUIElement) -> Bool {
        window.staticTexts.matching(NSPredicate(format: "value == %@ OR label == %@", value, value)).firstMatch.exists
    }
    private func fixtureDirectory() throws -> URL {
        var ancestor = Bundle(for: Self.self).bundleURL
        for _ in 0..<8 {
            let directory = ancestor.appendingPathComponent("Cassini.app/Contents/Resources/Fixtures")
            if FileManager.default.fileExists(atPath: directory.appendingPathComponent("Library/main/activity.json").path) { return directory }
            ancestor.deleteLastPathComponent()
        }
        throw NSError(domain: "CassiniLibraryBoards", code: 1)
    }
}
