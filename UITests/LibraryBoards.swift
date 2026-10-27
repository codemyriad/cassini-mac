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
    @MainActor func testTranscriptCanBeClosedAndReopened() throws {
        let app = try launch("library", fixture: "main"); defer { app.terminate() }
        let library = app.windows["cassini-library-window"]
        let read = library.buttons["preview-read-transcript"]
        XCTAssertTrue(read.waitForExistence(timeout: 20))
        for _ in 0..<3 {
            read.click()
            let transcript = app.windows["cassini-transcript-window"]
            XCTAssertTrue(transcript.waitForExistence(timeout: 10))
            transcript.buttons["_XCUI:CloseWindow"].click()
            let closed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: transcript)
            XCTAssertEqual(XCTWaiter.wait(for: [closed], timeout: 5), .completed)
            XCTAssertTrue(library.exists)
            XCTAssertTrue(app.state == .runningForeground)
        }
    }
    @MainActor func testOpenAndFinderRoutingWithLibraryClosed() async throws {
        let app = try launch("first-run", fixture: "empty"); defer { app.terminate() }
        let library = app.windows["cassini-library-window"]
        XCTAssertTrue(library.waitForExistence(timeout: 20))
        library.buttons["_XCUI:CloseWindow"].click()
        XCTAssertTrue(app.state == .runningForeground)
        app.typeKey("o", modifierFlags: .command)
        XCTAssertTrue(app.windows["open-panel"].waitForExistence(timeout: 5), app.debugDescription)
        app.typeKey(.escape, modifierFlags: [])
        let fixture = try fixtureDirectory().appendingPathComponent("meeting.opus")
        try await finderOpen(fixture)
        let viewer = app.windows["cassini-legacy-window"]
        XCTAssertTrue(viewer.waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertEqual(app.windows.matching(identifier: "cassini-legacy-window").count, 1)
        try await finderOpen(fixture)
        XCTAssertTrue(viewer.exists)
        XCTAssertEqual(app.windows.matching(identifier: "cassini-legacy-window").count, 1)
        XCTAssertFalse(library.exists, app.debugDescription)
    }
    @MainActor func testReceivedReadAndPlayReuseOneViewer() throws {
        let app = try launch("library", fixture: "main"); defer { app.terminate() }
        let library = app.windows["cassini-library-window"]
        let received = library.descendants(matching: .any).matching(identifier: "meeting-Received-a0000000-0000-4000-8000-000000000006").firstMatch
        XCTAssertTrue(received.waitForExistence(timeout: 20), app.debugDescription)
        received.click()
        library.buttons["preview-read-transcript"].click()
        let viewer = app.windows["cassini-legacy-window"]
        XCTAssertTrue(viewer.waitForExistence(timeout: 15), app.debugDescription)
        // Bring the Library forward without closing the received-file viewer.
        app.menuBars.menuBarItems["Window"].click()
        app.menuItems["Library"].click()
        library.buttons["preview-play"].click()
        XCTAssertTrue(viewer.exists)
        XCTAssertEqual(app.windows.matching(identifier: "cassini-legacy-window").count, 1)
    }
    @MainActor func testFailedReadClosesLoadingViewer() throws {
        let app = XCUIApplication(); defer { app.terminate() }
        app.launchEnvironment["CASSINI_HOSTED_SCREENSHOTS"] = "1"
        // Legacy fixture routing intentionally points to a nonexistent file.
        // That mode skips the real Library scanner and never starts playback.
        let absent = try fixtureDirectory().appendingPathComponent("absent-fixture")
        app.launchArguments = ["-CassiniScreenshot", "window", "-CassiniFixture", absent.path,
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
    @MainActor private func launch(_ name: String, fixture: String) throws -> XCUIApplication {
        let app = XCUIApplication()
        let root = try fixtureDirectory().appendingPathComponent("Library/" + fixture)
        app.launchEnvironment["CASSINI_HOSTED_SCREENSHOTS"] = "1"
        app.launchArguments = ["-CassiniScreenshot", name, "-CassiniFixture", root.path,
                               "-CassiniNow", "2026-10-27T13:18:00Z", "-ApplePersistenceIgnoreState", "YES",
                               "-AppleLanguages", "(en-GB)", "-AppleLocale", "en_GB", "-AppleInterfaceStyle", "Light", "-AppleAccentColor", "4"]
        app.launch(); return app
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
