// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import XCTest

final class D1197FocusAndControlsTests: AcceptanceTestCase {
    /// Item 1: search field keeps focus while typing at 1120x720 and 900x720 floating sidebar.
    @MainActor func testSearchKeepsFocusWhileTyping() throws {
        var failures: [String] = []

        // 1120x720 docked sidebar
        do {
            let app = try launchAcceptance("meeting", fixture: "main", size: "1120x720", dark: false)
            defer { app.terminate() }
            let window = app.windows["cassini-library-window"]
            XCTAssertTrue(window.waitForExistence(timeout: 20), app.debugDescription)

            let field = sidebarSearchField(in: window)
            XCTAssertTrue(field.waitForExistence(timeout: 10), app.debugDescription)
            field.click()
            field.typeText("travel")

            _ = attachWindowScreenshot(window, name: "b19-item1-docked-light")
            if (field.value as? String) != "travel" {
                failures.append("Docked search field value was \(String(describing: field.value)), expected 'travel'")
            }
            if !hasKeyboardFocus(field) {
                failures.append("Docked search field lost keyboard focus while typing")
            }
            let hits = window.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "search-hit-"))
            if !waitFor({ hits.count >= 1 }, timeout: 5) {
                failures.append("Docked search must show at least one search-hit-*")
            }
        }

        // 900x720 floating sidebar
        do {
            let narrow = try launchAcceptance("meeting", fixture: "main", size: "900x720", dark: false)
            defer { narrow.terminate() }
            let narrowWin = narrow.windows["cassini-library-window"]
            XCTAssertTrue(narrowWin.waitForExistence(timeout: 20), narrow.debugDescription)
            openFloatingSidebar(in: narrow, window: narrowWin)
            let floatingField = sidebarSearchField(in: narrowWin)
            XCTAssertTrue(floatingField.waitForExistence(timeout: 10), narrow.debugDescription)
            floatingField.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
            narrow.typeText("travel")

            _ = attachWindowScreenshot(narrowWin, name: "b19-item1-floating-light")
            if (floatingField.value as? String) != "travel" {
                failures.append("Floating search field value was \(String(describing: floatingField.value)), expected 'travel'")
            }
            if !hasKeyboardFocus(floatingField) {
                failures.append("Floating search field lost keyboard focus while typing")
            }
            let floatingHits = narrowWin.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "search-hit-"))
            if !waitFor({ floatingHits.count >= 1 }, timeout: 5) {
                failures.append("Floating sidebar must show at least one search-hit-*")
            }
        }

        XCTAssertTrue(failures.isEmpty, "[D-1197-item1] \(failures.joined(separator: "; "))")
    }

    /// Item 4: All / Starred filter control matches mock in light and dark, active and inactive.
    @MainActor func testFilterControlMatchesMock() throws {
        let finder = XCUIApplication(bundleIdentifier: "com.apple.finder")
        var failures: [String] = []

        for dark in [false, true] {
            let scheme = dark ? "dark" : "light"
            let app = try launchAcceptance("library", fixture: "main", size: "1120x720", dark: dark)
            defer { app.terminate() }
            let window = app.windows["cassini-library-window"]
            let filters = window.descendants(matching: .any)["library-filters"].firstMatch
            XCTAssertTrue(filters.waitForExistence(timeout: 20), app.debugDescription)

            let allSegment = filters.radioButtons["All"].firstMatch
            let starredSegment = filters.radioButtons["Starred"].firstMatch
            XCTAssertTrue(allSegment.exists && starredSegment.exists, "Both All and Starred segments must exist inside library-filters")

            for (label, seg) in [("all", allSegment), ("starred", starredSegment)] {
                seg.click()
                let activeShot = attachWindowScreenshot(window, name: "b19-item4-\(label)-active-\(scheme)")
                let activeImg = try PixelImage(screenshot: activeShot, windowFrame: window.frame)
                let filterRect = activeImg.windowRect(for: filters.frame)
                let segRect = activeImg.windowRect(for: seg.frame)
                if abs(segRect.height - 22.0) > 1.0 {
                    failures.append("Selected segment capsule height \(segRect.height) != 22 ±1 (\(label) \(scheme))")
                }
                if activeImg.containsAccentBlue(inPointRect: filterRect) {
                    failures.append("Accent blue found in library-filters (\(label) active \(scheme))")
                }
                let center = activeImg.color(atPoint: CGPoint(x: segRect.midX, y: segRect.midY))
                if !dark {
                    if center.r < 250 || center.g < 250 || center.b < 250 {
                        failures.append("Light selected segment center rgb=(\(center.r),\(center.g),\(center.b)) < 250 (\(label))")
                    }
                } else {
                    if center.r < 40 || center.r > 85 {
                        failures.append("Dark selected segment center r=\(center.r) outside 40...85 (\(label))")
                    }
                }
                if !(seg.isSelected || (seg.value as? NSNumber)?.intValue == 1) {
                    failures.append("Selected option \(label) did not expose selected state (\(scheme))")
                }

                finder.activate()
                let inactiveShot = attachWindowScreenshot(window, name: "b19-item4-\(label)-inactive-\(scheme)")
                let inactiveImg = try PixelImage(screenshot: inactiveShot, windowFrame: window.frame)
                if inactiveImg.containsAccentBlue(inPointRect: filterRect) {
                    failures.append("Accent blue found in library-filters when inactive (\(label) \(scheme))")
                }
                app.activate()
            }

            filters.click()
            window.typeKey(.leftArrow, modifierFlags: [])
            if !(allSegment.isSelected || (allSegment.value as? NSNumber)?.intValue == 1) {
                failures.append("Left arrow did not select All (\(scheme))")
            }
            window.typeKey(.rightArrow, modifierFlags: [])
            if !(starredSegment.isSelected || (starredSegment.value as? NSNumber)?.intValue == 1) {
                failures.append("Right arrow did not select Starred (\(scheme))")
            }
        }

        XCTAssertTrue(failures.isEmpty, "[D-1197-item4] \(failures.joined(separator: "; "))")
    }

    /// Item 15: Page buttons ("Transcribe again" and "Open System Settings") stay the same colour when inactive.
    @MainActor func testPageButtonsSameWhenInactive() throws {
        let finder = XCUIApplication(bundleIdentifier: "com.apple.finder")
        var failures: [String] = []

        for dark in [false, true] {
            let scheme = dark ? "dark" : "light"
            let app = try launchAcceptance("library", fixture: "main", size: "1120x720", dark: dark, extra: ["-CassiniNoSpeechFixture", "YES"])
            defer { app.terminate() }
            let window = app.windows["cassini-library-window"]
            let writeAgain = window.buttons["transcript-write-down-again"].firstMatch
            XCTAssertTrue(writeAgain.waitForExistence(timeout: 20), app.debugDescription)
            let openSettings = window.buttons["transcript-no-speech-permission-settings"].firstMatch
            XCTAssertTrue(openSettings.waitForExistence(timeout: 10), app.debugDescription)

            let activeShot = attachWindowScreenshot(window, name: "b19-item15-active-\(scheme)")
            let activeImg = try PixelImage(screenshot: activeShot, windowFrame: window.frame)

            finder.activate()
            let inactiveShot = attachWindowScreenshot(window, name: "b19-item15-inactive-\(scheme)")
            let inactiveImg = try PixelImage(screenshot: inactiveShot, windowFrame: window.frame)
            app.activate()

            for (name, button) in [("Transcribe again", writeAgain), ("Open System Settings", openSettings)] {
                let rect = activeImg.windowRect(for: button.frame)
                let activeMean = activeImg.meanColor(inPointRect: rect)
                let inactiveMean = inactiveImg.meanColor(inPointRect: rect)
                let diff = activeMean.maxChannelDiff(to: inactiveMean)
                if diff > 3.0 {
                    failures.append("\(name) button mean colour diff \(diff) > 3 when inactive (\(scheme))")
                }
            }
        }

        XCTAssertTrue(failures.isEmpty, "[D-1197-item15] \(failures.joined(separator: "; "))")
    }

    /// Item 16: Clicking away ends editing in sidebar search, meeting find, and title rename.
    @MainActor func testClickAwayEndsEditing() throws {
        let app = try launchAcceptance(
            "meeting",
            fixture: "main",
            size: "1120x720",
            dark: false,
            extra: ["--fixture-library-rename", "-CassiniRenameID", UUID().uuidString]
        )
        defer { app.terminate() }
        let window = app.windows["cassini-library-window"]
        XCTAssertTrue(window.waitForExistence(timeout: 20), app.debugDescription)

        let field = sidebarSearchField(in: window)
        XCTAssertTrue(field.waitForExistence(timeout: 10), app.debugDescription)
        field.click()
        field.typeText("travel")
        let hits = window.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "search-hit-"))
        XCTAssertTrue(waitFor({ hits.count >= 1 }, timeout: 5))
        let initialHitCount = hits.count

        let transcript = window.descendants(matching: .any)["meeting-transcript"].firstMatch
        let meetingPage = window.descendants(matching: .any)["meeting-page"].firstMatch
        let toolbar = window.toolbars.firstMatch
        XCTAssertTrue(transcript.exists && meetingPage.exists && toolbar.exists, app.debugDescription)

        var failures: [String] = []
        let targets: [(String, CGPoint)] = [
            ("transcript", CGPoint(x: transcript.frame.midX, y: transcript.frame.midY)),
            ("meeting-page", CGPoint(x: meetingPage.frame.maxX - 16, y: meetingPage.frame.midY)),
            ("player-bar", CGPoint(x: meetingPage.frame.midX, y: meetingPage.frame.maxY - 20)),
            ("toolbar", CGPoint(x: toolbar.frame.midX, y: toolbar.frame.midY)),
        ]
        for (label, point) in targets {
            field.click()
            let coord = window.coordinate(withNormalizedOffset: .zero).withOffset(
                CGVector(dx: point.x - window.frame.minX, dy: point.y - window.frame.minY)
            )
            coord.click()
            _ = attachWindowScreenshot(window, name: "b19-item16-click-\(label)-light")
            if hasKeyboardFocus(field) {
                failures.append("Search field kept keyboard focus after clicking \(label)")
            }
            if hits.count != initialHitCount {
                failures.append("Hit count changed from \(initialHitCount) to \(hits.count) after clicking \(label)")
            }
        }

        // Clear field and click transcript -> search closes and meeting list shows.
        field.click()
        field.typeKey("a", modifierFlags: .command)
        field.typeKey(.delete, modifierFlags: [])
        transcript.click()
        if !waitFor({ hits.count == 0 }, timeout: 5) {
            failures.append("Clearing search and clicking away did not close search")
        }

        // Meeting find (⌘F): type word, click transcript -> find field loses focus, count unchanged, bar stays.
        window.typeKey("f", modifierFlags: .command)
        let findField = window.textFields["meeting-find"].firstMatch
        XCTAssertTrue(findField.waitForExistence(timeout: 5), app.debugDescription)
        findField.typeText("budget")
        let countEl = window.staticTexts["meeting-find-count"].firstMatch
        let countBefore = visibleText(countEl)
        transcript.click()
        if hasKeyboardFocus(findField) {
            failures.append("Find field kept focus when clicking transcript")
        }
        if visibleText(countEl) != countBefore {
            failures.append("Find count changed after clicking transcript")
        }
        if !findField.exists {
            failures.append("Find bar disappeared after clicking transcript")
        }

        // Big title rename: click meeting-inline-title, type, click transcript -> editing ends.
        let heading = window.descendants(matching: .any)["meeting-inline-title"].firstMatch
        XCTAssertTrue(heading.exists, "meeting-inline-title must exist")
        heading.click()
        let editor = window.textFields["meeting-inline-title-editor"].firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 5), app.debugDescription)
        editor.typeText(" edited")
        transcript.click()
        if !waitFor({ !editor.exists }, timeout: 5) {
            failures.append("Clicking transcript did not end title rename")
        }

        XCTAssertTrue(failures.isEmpty, "[D-1197-item16] \(failures.joined(separator: "; "))")
    }
}
