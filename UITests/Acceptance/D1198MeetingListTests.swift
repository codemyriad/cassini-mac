// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import XCTest

final class D1198MeetingListTests: AcceptanceTestCase {
    /// Item 2: No horizontal line under day headings, and headings scroll (not pinned).
    @MainActor func testNoLineUnderDayHeadings() throws {
        var failures: [String] = []

        for dark in [false, true] {
            let scheme = dark ? "dark" : "light"
            let app = try launchAcceptance("library", fixture: "main", size: "1120x720", dark: dark)
            defer { app.terminate() }
            let window = app.windows["cassini-library-window"]
            let headers = window.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "library-day-header-"))
            XCTAssertTrue(waitFor({ headers.count >= 2 }, timeout: 20), app.debugDescription)

            let shot = attachWindowScreenshot(window, name: "b19-item2-top-\(scheme)")
            let img = try PixelImage(screenshot: shot, windowFrame: window.frame)

            let firstHeader = headers.element(boundBy: 0)
            let firstHeaderTopBefore = firstHeader.frame.minY
            let sidebarRight = min(380.0, window.frame.width * 0.35)
            let ground = img.color(atPoint: CGPoint(x: 6, y: img.windowRect(for: firstHeader.frame).midY))

            for i in 0..<min(headers.count, 3) {
                let h = headers.element(boundBy: i)
                let hRect = img.windowRect(for: h.frame)
                for dy in stride(from: CGFloat(1), through: 8, by: 1) {
                    let y = hRect.maxY + dy
                    let frac = img.rowDifferenceFraction(atY: y, fromX: 10, toX: sidebarRight - 10, against: ground, threshold: 6)
                    if frac > 0.5 {
                        failures.append("Divider line at y=\(y) below day header \(i) (frac=\(frac), \(scheme))")
                    }
                }
            }

            // Scroll the list and verify the first heading moved (not pinned).
            let list = window.outlines.firstMatch.exists ? window.outlines.firstMatch : window.scrollViews.firstMatch
            list.scroll(byDeltaX: 0, deltaY: -200)
            _ = attachWindowScreenshot(window, name: "b19-item2-scrolled-\(scheme)")
            if abs(firstHeader.frame.minY - firstHeaderTopBefore) <= 1.0 {
                failures.append("First day header stayed pinned on scroll (\(scheme))")
            }
        }

        expectStrictFailure("D-1198 item 2", matching: "[D-1198-item2]") {
            XCTAssertTrue(failures.isEmpty, "[D-1198-item2] \(failures.joined(separator: "; "))")
        }
    }

    /// Item 3: Visible cards align horizontally with the search field (±1 pt) and day headings align with card titles.
    @MainActor func testCardsLineUpWithSearchField() throws {
        let app = try launchAcceptance("library", fixture: "main", size: "1120x720", dark: false)
        defer { app.terminate() }
        let window = app.windows["cassini-library-window"]
        let searchField = sidebarSearchField(in: window)
        XCTAssertTrue(searchField.waitForExistence(timeout: 20), app.debugDescription)

        let shot = attachWindowScreenshot(window, name: "b19-item3-alignment-light")
        let img = try PixelImage(screenshot: shot, windowFrame: window.frame)
        let searchRect = img.windowRect(for: searchField.frame)

        let cards = window.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "meeting-card-"))
        XCTAssertGreaterThan(cards.count, 0, "Expected meeting-card-* elements")

        let sidebarGround = img.color(atPoint: CGPoint(x: 4, y: searchRect.maxY + 6))
        var failures: [String] = []
        for i in 0..<min(cards.count, 4) {
            let card = cards.element(boundBy: i)
            let cardRect = img.windowRect(for: card.frame)
            let bounds = img.drawnHorizontalBounds(inPointRect: cardRect, against: sidebarGround, threshold: 6)
            let left = bounds?.left ?? cardRect.minX
            let right = bounds?.right ?? cardRect.maxX
            if abs(left - searchRect.minX) > 1.0 {
                failures.append("Card \(i) left \(left) != search left \(searchRect.minX) ±1")
            }
            if abs(right - searchRect.maxX) > 1.0 {
                failures.append("Card \(i) right \(right) != search right \(searchRect.maxX) ±1")
            }
        }

        expectStrictFailure("D-1198 item 3", matching: "[D-1198-item3]") {
            XCTAssertTrue(failures.isEmpty, "[D-1198-item3] \(failures.joined(separator: "; "))")
        }
    }

    /// Item 12: Context-menu ring only wraps the card (grown by 4 pt) and clears on Esc / click away / action.
    @MainActor func testContextMenuRingOnlyOnCard() throws {
        var failures: [String] = []

        for dark in [false, true] {
            let scheme = dark ? "dark" : "light"
            let app = try launchAcceptance("library", fixture: "main", size: "1120x720", dark: dark)
            defer { app.terminate() }
            let window = app.windows["cassini-library-window"]
            let cards = window.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "meeting-card-"))
            XCTAssertTrue(waitFor({ cards.count >= 2 }, timeout: 20), app.debugDescription)

            let unselected = cards.element(boundBy: 1)
            unselected.rightClick()
            let openShot = attachWindowScreenshot(window, name: "b19-item12-menu-open-\(scheme)")
            let openImg = try PixelImage(screenshot: openShot, windowFrame: window.frame)
            let cardRect = openImg.windowRect(for: unselected.frame)
            let leftMargin = CGRect(x: 0, y: cardRect.minY, width: max(0, cardRect.minX - 4), height: cardRect.height)
            if openImg.containsAccentBlue(inPointRect: leftMargin) {
                failures.append("Accent blue bled outside card left +4 pt (\(scheme))")
            }

            window.typeKey(.escape, modifierFlags: [])
            let escShot = attachWindowScreenshot(window, name: "b19-item12-after-esc-\(scheme)")
            let escImg = try PixelImage(screenshot: escShot, windowFrame: window.frame)
            if escImg.containsAccentBlue(inPointRect: cardRect.insetBy(dx: -6, dy: -6)) {
                failures.append("Context menu ring did not clear after Esc (\(scheme))")
            }
        }

        expectStrictFailure("D-1198 item 12", matching: "[D-1198-item12]") {
            XCTAssertTrue(failures.isEmpty, "[D-1198-item12] \(failures.joined(separator: "; "))")
        }
    }

    /// Item 17: List fades under footer at 1120 and 900 floating sidebar, light and dark.
    @MainActor func testListFadesUnderFooter() throws {
        var failures: [String] = []

        for dark in [false, true] {
            let scheme = dark ? "dark" : "light"
            for size in ["1120x720", "900x720"] {
                let app = try launchAcceptance("library", fixture: "main", size: size, dark: dark, extra: ["-CassiniLongLibraryFixture", "YES"])
                defer { app.terminate() }
                let window = app.windows["cassini-library-window"]
                XCTAssertTrue(window.waitForExistence(timeout: 20), app.debugDescription)
                if size == "900x720" {
                    let toggle = window.buttons["floating-sidebar-toggle"].firstMatch
                    if toggle.waitForExistence(timeout: 5) { toggle.click() }
                }
                let footer = window.descendants(matching: .any)["library-drop-hint"].firstMatch
                XCTAssertTrue(footer.waitForExistence(timeout: 10), app.debugDescription)

                let list = window.outlines.firstMatch.exists ? window.outlines.firstMatch : window.scrollViews.firstMatch
                list.scroll(byDeltaX: 0, deltaY: -300)

                let shot = attachWindowScreenshot(window, name: "b19-item17-\(size)-\(scheme)")
                let img = try PixelImage(screenshot: shot, windowFrame: window.frame)
                let footerRect = img.windowRect(for: footer.frame)
                let ground = img.color(atPoint: CGPoint(x: footerRect.minX + 2, y: footerRect.midY))

                let fadeBand = CGRect(x: footerRect.minX, y: max(0, footerRect.minY - 24), width: footerRect.width, height: 24)
                let upperBand = CGRect(x: footerRect.minX, y: max(0, footerRect.minY - 124), width: footerRect.width, height: 24)
                let fadeContrast = img.maxContrast(inPointRect: fadeBand, against: ground)
                let upperContrast = img.maxContrast(inPointRect: upperBand, against: ground)
                if !(fadeContrast < upperContrast * 0.5) {
                    failures.append("Fade contrast \(fadeContrast) not < half of upper \(upperContrast) (\(size) \(scheme))")
                }
            }
        }

        expectStrictFailure("D-1198 item 17", matching: "[D-1198-item17]") {
            XCTAssertTrue(failures.isEmpty, "[D-1198-item17] \(failures.joined(separator: "; "))")
        }
    }

    /// Regression guard (unwrapped): basic list selection, keyboard navigation, and VoiceOver labels must pass before and after.
    @MainActor func testListSelectionKeyboardAndVoiceOverGuards() throws {
        let app = try launchAcceptance("library", fixture: "main", size: "1120x720", dark: false)
        defer { app.terminate() }
        let window = app.windows["cassini-library-window"]
        let cards = window.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "meeting-card-"))
        XCTAssertTrue(waitFor({ cards.count >= 2 }, timeout: 20), app.debugDescription)

        let first = cards.element(boundBy: 0)
        first.click()
        window.typeKey(.downArrow, modifierFlags: [])
        window.typeKey(.upArrow, modifierFlags: [])
        window.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(window.descendants(matching: .any)["meeting-page"].waitForExistence(timeout: 10))
        _ = attachWindowScreenshot(window, name: "b19-item-list-guard-light")
    }
}
