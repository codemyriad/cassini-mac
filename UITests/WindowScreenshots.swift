import AppKit
import XCTest
import Darwin

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
    func testEscapeKeepsRecording() throws {
        try capture("sheet", attachment: nil, withSheet: true, dismissUsing: .escape)
    }

    @MainActor
    private func capture(_ name: String, attachment: String?, withSheet: Bool,
                         dismissUsing key: XCUIKeyboardKey = .return) throws {
        try dismissDedicatedRunnerNotifications()
        let app = XCUIApplication()
        let fixture = try fixtureDirectory()
        app.launchEnvironment["CASSINI_HOSTED_SCREENSHOTS"] = "1"
        app.launchArguments = ["-CassiniScreenshot", name, "-CassiniFixture", fixture.path,
                               "-CassiniNow", "2026-10-27T12:00:00Z",
                               "-ApplePersistenceIgnoreState", "YES"]
        let boardSize = ProcessInfo.processInfo.environment["CASSINI_SCREENSHOT_SIZE"] == "1120x720"
        if boardSize { app.launchArguments += ["-CassiniScreenshotSize", "1120x720"] }
        app.launch()
        defer { app.terminate() }
        let window = app.windows["cassini-screenshot-window"]
        XCTAssertTrue(window.waitForExistence(timeout: 20), app.debugDescription)
        XCTAssertTrue(window.toolbars.firstMatch.waitForExistence(timeout: 5), window.debugDescription)
        XCTAssertEqual(window.frame.width, boardSize ? 1120 : 960, accuracy: 2)
        XCTAssertEqual(window.frame.height, boardSize ? 720 : 640, accuracy: 2)
        let screen = try XCTUnwrap(NSScreen.main)
        XCTAssertGreaterThanOrEqual(window.frame.minX, 0)
        XCTAssertGreaterThanOrEqual(window.frame.minY, 0)
        XCTAssertLessThanOrEqual(window.frame.maxX, screen.frame.width)
        XCTAssertLessThanOrEqual(window.frame.maxY, screen.frame.height)
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
        if let attachment {
            let image = XCTAttachment(screenshot: screenshot)
            image.name = attachment
            image.lifetime = .keepAlways
            add(image)
        }
        if withSheet {
            app.typeKey(key, modifierFlags: [])
            let resultID = key == .escape ? "cassini-screenshot-kept" : "cassini-screenshot-stopped"
            XCTAssertTrue(app.windows[resultID].waitForExistence(timeout: 5), app.debugDescription)
        }
    }

    @MainActor private func dismissDedicatedRunnerNotifications() throws {
        guard ProcessInfo.processInfo.environment["CASSINI_GUI_SCREENSHOTS"] == "1" else { return }
        let console = try FileManager.default.attributesOfItem(atPath:"/dev/console")[.ownerAccountID] as? NSNumber
        guard getuid() == 503, console?.uint32Value == 503 else {
            throw NSError(domain:"CassiniScreenshots",code:2,
                          userInfo:[NSLocalizedDescriptionKey:"Notification cleanup requires the dedicated CI console"])
        }
        let center = XCUIApplication(bundleIdentifier:"com.apple.notificationcenterui")
        guard center.state != .notRunning else { return }
        // First-login macOS notices persist across Notification Center restarts.
        // Use ordinary Close actions in this isolated account, without TCC edits
        // or an Accessibility grant to a shell helper.
        for window in center.windows.allElementsBoundByIndex where window.isHittable {
            window.hover()
        }
        for _ in 0..<10 {
            let close = center.buttons.matching(NSPredicate(format:"label == %@", "Close"))
                .allElementsBoundByIndex.first(where:{ $0.isHittable })
            guard let close else { break }
            close.click()
        }
        let tree = XCTAttachment(string:center.debugDescription)
        tree.name = "dedicated-runner-notifications"; tree.lifetime = .keepAlways; add(tree)
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
