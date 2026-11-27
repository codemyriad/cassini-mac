// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import XCTest

final class D1197FocusAndControlsTests: AcceptanceTestCase {
    /// Item 1: search field keeps focus while typing at 1120x720 and 900x720 floating sidebar.
    @MainActor func testSearchKeepsFocusWhileTyping() throws {
        expectStrictFailure("D-1197 item 1") {
            // 1120x720 docked sidebar
            let app = try launchAcceptance("meeting", fixture: "main", size: "1120x720", dark: false)
            defer { app.terminate() }
            let window = app.windows["cassini-library-window"]
            XCTAssertTrue(window.waitForExistence(timeout: 20), app.debugDescription)

            let field = sidebarSearchField(in: window)
            XCTAssertTrue(field.waitForExistence(timeout: 10), app.debugDescription)
            field.click()
            field.typeText("travel")

            _ = attachWindowScreenshot(window, name: "b19-item1-docked-light")
            XCTAssertEqual(field.value as? String, "travel", "Search field must keep full typed text")
            XCTAssertTrue(hasKeyboardFocus(field), "Search field must retain keyboard focus while typing")
            let hits = window.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "search-hit-"))
            XCTAssertTrue(waitFor({ hits.count >= 1 }, timeout: 5), "At least one search-hit-* must show")
            app.terminate()

            // 900x720 floating sidebar
            let narrow = try launchAcceptance("meeting", fixture: "main", size: "900x720", dark: false)
            defer { narrow.terminate() }
            let narrowWin = narrow.windows["cassini-library-window"]
            XCTAssertTrue(narrowWin.waitForExistence(timeout: 20), narrow.debugDescription)
            let toggle = narrowWin.buttons["floating-sidebar-toggle"].firstMatch
            if toggle.waitForExistence(timeout: 5) {
                toggle.click()
            } else {
                narrow.typeKey("s", modifierFlags: [.command, .control])
            }
            let floatingField = sidebarSearchField(in: narrowWin)
            XCTAssertTrue(floatingField.waitForExistence(timeout: 10), narrow.debugDescription)
            floatingField.click()
            floatingField.typeText("travel")

            _ = attachWindowScreenshot(narrowWin, name: "b19-item1-floating-light")
            XCTAssertEqual(floatingField.value as? String, "travel", "Floating sidebar search field must keep full typed text")
            XCTAssertTrue(hasKeyboardFocus(floatingField), "Floating sidebar search field must retain keyboard focus")
            let floatingHits = narrowWin.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "search-hit-"))
            XCTAssertTrue(waitFor({ floatingHits.count >= 1 }, timeout: 5), "Floating sidebar must show at least one search-hit-*")
        }
    }

    /// Item 4: All / Starred filter control matches mock in light and dark, active and inactive.
    @MainActor func testFilterControlMatchesMock() throws {
        expectStrictFailure("D-1197 item 4") {
            let finder = XCUIApplication(bundleIdentifier: "com.apple.finder")
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
                    // Active check
                    let activeShot = attachWindowScreenshot(window, name: "b19-item4-\(label)-active-\(scheme)")
                    let activeImg = try PixelImage(screenshot: activeShot, windowFrame: window.frame)
                    let filterRect = activeImg.windowRect(for: filters.frame)
                    let segRect = activeImg.windowRect(for: seg.frame)
                    XCTAssertEqual(segRect.height, 22, accuracy: 1.0, "Selected segment capsule height must be 22 pt ±1")
                    XCTAssertFalse(activeImg.containsAccentBlue(inPointRect: filterRect), "No pixel in library-filters may be accent blue (\(label) active \(scheme))")
                    let center = activeImg.color(atPoint: CGPoint(x: segRect.midX, y: segRect.midY))
                    if !dark {
                        XCTAssertGreaterThanOrEqual(center.r, 250, "Light selected segment center R >= 250")
                        XCTAssertGreaterThanOrEqual(center.g, 250, "Light selected segment center G >= 250")
                        XCTAssertGreaterThanOrEqual(center.b, 250, "Light selected segment center B >= 250")
                    } else {
                        // Dark mock raised fill (~58-64 sRGB) ±6
                        XCTAssertGreaterThanOrEqual(center.r, 40)
                        XCTAssertLessThanOrEqual(center.r, 85)
                    }
                    XCTAssertTrue(seg.isSelected || (seg.value as? NSNumber)?.intValue == 1, "Selected option must expose selected state")

                    // Inactive check
                    finder.activate()
                    let inactiveShot = attachWindowScreenshot(window, name: "b19-item4-\(label)-inactive-\(scheme)")
                    let inactiveImg = try PixelImage(screenshot: inactiveShot, windowFrame: window.frame)
                    XCTAssertFalse(inactiveImg.containsAccentBlue(inPointRect: filterRect), "No pixel in library-filters may be accent blue when inactive")
                    app.activate()
                }

                // Keyboard ← and → change the choice.
                filters.click()
                window.typeKey(.leftArrow, modifierFlags: [])
                XCTAssertTrue(allSegment.isSelected || (allSegment.value as? NSNumber)?.intValue == 1, "Left arrow selects All")
                window.typeKey(.rightArrow, modifierFlags: [])
                XCTAssertTrue(starredSegment.isSelected || (starredSegment.value as? NSNumber)?.intValue == 1, "Right arrow selects Starred")
                app.terminate()
            }
        }
    }

    /// Item 15: Page buttons ("Transcribe again" and "Open System Settings") stay the same colour when inactive.
    @MainActor func testPageButtonsSameWhenInactive() throws {
        expectStrictFailure("D-1197 item 15") {
            let finder = XCUIApplication(bundleIdentifier: "com.apple.finder")
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
                    XCTAssertLessThanOrEqual(activeMean.maxChannelDiff(to: inactiveMean), 3.0, "\(name) button mean colour must differ by <= 3 when inactive (\(scheme))")
                }
                app.terminate()
            }
        }
    }

    /// Item 16: Clicking away ends editing in sidebar search, meeting find, and title rename.
    @MainActor func testClickAwayEndsEditing() throws {
        expectStrictFailure("D-1197 item 16") {
            let app = try launchAcceptance("meeting", fixture: "main", size: "1120x720", dark: false)
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

            // Click transcript, empty meeting-page, empty player bar area, and empty toolbar.
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
                XCTAssertFalse(hasKeyboardFocus(field), "Search field must lose keyboard focus after clicking \(label)")
                XCTAssertEqual(hits.count, initialHitCount, "Hit count must stay unchanged after clicking \(label)")
            }

            // Clear field and click transcript -> search closes and meeting list shows.
            field.click()
            field.typeKey("a", modifierFlags: .command)
            field.typeKey(.delete, modifierFlags: [])
            transcript.click()
            XCTAssertTrue(waitFor({ hits.count == 0 }, timeout: 5), "Clearing search and clicking away must close search")

            // Meeting find (⌘F): type word, click transcript -> find field loses focus, count unchanged, bar stays.
            window.typeKey("f", modifierFlags: .command)
            let findField = window.textFields["meeting-find"].firstMatch
            XCTAssertTrue(findField.waitForExistence(timeout: 5), app.debugDescription)
            findField.typeText("budget")
            let countEl = window.staticTexts["meeting-find-count"].firstMatch
            let countBefore = visibleText(countEl)
            transcript.click()
            XCTAssertFalse(hasKeyboardFocus(findField), "Find field must lose focus when clicking transcript")
            XCTAssertEqual(visibleText(countEl), countBefore)
            XCTAssertTrue(findField.exists, "Find bar must stay visible")

            // Big title rename: click meeting-heading, type, click transcript -> editing ends.
            let heading = window.descendants(matching: .any)["meeting-inline-title"].firstMatch
            if heading.exists {
                heading.click()
                let editor = window.textFields["meeting-inline-title-editor"].firstMatch
                XCTAssertTrue(editor.waitForExistence(timeout: 5))
                editor.typeText(" edited")
                transcript.click()
                XCTAssertTrue(waitFor({ !editor.exists }, timeout: 5), "Clicking transcript must end title rename")
            }
        }
    }
}
