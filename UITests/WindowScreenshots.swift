import XCTest

final class WindowScreenshots: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        // A local build-for-testing is safe; running this suite is hosted-only.
        try XCTSkipUnless(ProcessInfo.processInfo.environment["CASSINI_HOSTED_SCREENSHOTS"] == "1",
                          "Window screenshots run only on the GitHub-hosted macOS runner")
    }

    @MainActor
    func testWholeWindow() throws {
        try capture("window", attachment: "current-window", withSheet: false)
    }

    @MainActor
    func testWholeWindowWithSheet() throws {
        try capture("sheet", attachment: "current-window-sheet", withSheet: true)
    }

    @MainActor
    private func capture(_ name: String, attachment: String, withSheet: Bool) throws {
        let app = XCUIApplication()
        let fixture = try fixtureDirectory()
        app.launchEnvironment["CASSINI_HOSTED_SCREENSHOTS"] = "1"
        app.launchArguments = ["-CassiniScreenshot", name, "-CassiniFixture", fixture.path,
                               "-CassiniNow", "2026-10-27T12:00:00Z",
                               "-ApplePersistenceIgnoreState", "YES"]
        app.launch()
        defer { app.terminate() }
        let window = app.windows["cassini-screenshot-window"]
        XCTAssertTrue(window.waitForExistence(timeout: 20), app.debugDescription)
        XCTAssertTrue(window.toolbars.firstMatch.waitForExistence(timeout: 5), window.debugDescription)
        XCTAssertEqual(window.frame.width, 1120, accuracy: 2)
        XCTAssertEqual(window.frame.height, 640, accuracy: 2)
        if withSheet {
            XCTAssertTrue(window.sheets.firstMatch.waitForExistence(timeout: 5), window.debugDescription)
            XCTAssertTrue(window.sheets.staticTexts["A recording is running"].exists)
            XCTAssertTrue(window.sheets.buttons["Keep recording"].exists)
            XCTAssertTrue(window.sheets.buttons["Stop and keep it"].exists)
        } else {
            XCTAssertFalse(window.sheets.firstMatch.exists)
        }
        // Capturing the AX window includes its titlebar/toolbar AND attached sheet.
        // A content-hosting view snapshot would omit those native surfaces.
        let screenshot = window.screenshot()
        XCTAssertGreaterThan(screenshot.pngRepresentation.count, 10_000)
        let image = XCTAttachment(screenshot: screenshot)
        image.name = attachment
        image.lifetime = .keepAlways
        add(image)
    }

    private func fixtureDirectory() throws -> URL {
        var ancestor = Bundle(for: Self.self).bundleURL
        for _ in 0..<8 {
            let directory = ancestor.appendingPathComponent("Cassini.app/Contents/Resources/Fixtures")
            if FileManager.default.fileExists(atPath: directory.appendingPathComponent("meeting.opus").path) {
                return directory
            }
            ancestor.deleteLastPathComponent()
        }
        throw NSError(domain: "CassiniScreenshots", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "Built app's bundled screenshot fixture is missing"])
    }
}
