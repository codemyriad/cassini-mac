import XCTest

final class LibraryBoards: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        try XCTSkipUnless(ProcessInfo.processInfo.environment["CASSINI_HOSTED_SCREENSHOTS"] == "1" && ProcessInfo.processInfo.environment["CASSINI_LIBRARY_BOARDS"] == "1", "Hosted-only Library boards")
    }
    @MainActor func testLibrary() throws { try board("library", fixture: "main") }
    @MainActor func testFirstRun() throws { try board("first-run", fixture: "empty") }
    @MainActor private func board(_ name: String, fixture: String) throws {
        let app = XCUIApplication()
        let root = try fixtureDirectory().appendingPathComponent("Library/" + fixture)
        app.launchEnvironment["CASSINI_HOSTED_SCREENSHOTS"] = "1"
        app.launchArguments = ["-CassiniScreenshot", name, "-CassiniFixture", root.path,
                               "-CassiniNow", "2026-10-27T13:18:00Z", "-ApplePersistenceIgnoreState", "YES",
                               "-AppleLanguages", "(en-GB)", "-AppleLocale", "en_GB", "-AppleInterfaceStyle", "Light", "-AppleAccentColor", "4"]
        app.launch(); defer { app.terminate() }
        let window = app.windows["cassini-library-window"]
        XCTAssertTrue(window.waitForExistence(timeout: 20), app.debugDescription)
        let expectedControl = name == "library" ? "preview-read-transcript" : "first-run-record"
        XCTAssertTrue(window.buttons[expectedControl].waitForExistence(timeout: 20), window.debugDescription)
        let attachment = XCTAttachment(screenshot: window.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        if name == "library" {
            XCTAssertTrue(window.buttons["preview-read-transcript"].waitForExistence(timeout: 20), window.debugDescription)
            XCTAssertTrue(window.descendants(matching: .any).matching(NSPredicate(format: "value CONTAINS %@ OR label CONTAINS %@", "52 min · Marta, Dario, Speaker 3", "52 min · Marta, Dario, Speaker 3")).firstMatch.exists)
            XCTAssertTrue(text("Today, 09:00 · 52 min", in: window))
            XCTAssertTrue(text("00:00:04", in: window))
            XCTAssertFalse(window.buttons["preview-play"].isEnabled)
        } else {
            XCTAssertTrue(window.buttons["first-run-record"].waitForExistence(timeout: 20), window.debugDescription)
            XCTAssertTrue(text("Your recorded meetings will appear here.", in: window))
            XCTAssertTrue(text("Recordings and transcripts stay on this computer, in Music/Cassini.", in: window))
        }
        XCTAssertEqual(window.frame.width, 1120, accuracy: 0.1)
        XCTAssertEqual(window.frame.height, 720, accuracy: 0.1)
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
