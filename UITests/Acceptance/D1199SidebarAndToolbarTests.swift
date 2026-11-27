// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import XCTest

final class D1199SidebarAndToolbarTests: AcceptanceTestCase {
    /// Items 5 and 6: Closed sidebar toolbar has no hittable Import, exactly one Record, no overflow (»),
    /// and shows toolbar-live-pill (with no Record) while recording.
    @MainActor func testClosedSidebarToolbar() throws {
        expectStrictFailure("D-1199 items 5 and 6") {
            for size in ["1120x720", "900x720", "560x720"] {
                let app = try launchAcceptance("meeting", fixture: "main", size: size, dark: false)
                defer { app.terminate() }
                let window = app.windows["cassini-library-window"]
                XCTAssertTrue(window.waitForExistence(timeout: 20), app.debugDescription)

                // Hide sidebar if open at 1120
                if size == "1120x720" {
                    app.typeKey("s", modifierFlags: [.command, .control])
                }
                _ = attachWindowScreenshot(window, name: "b19-item5-6-closed-\(size)-light")

                let imports = window.buttons.matching(identifier: "toolbar-import").allElementsBoundByIndex.filter(\.isHittable)
                XCTAssertEqual(imports.count, 0, "Closed sidebar at \(size) must have no hittable toolbar-import")

                let records = window.buttons.matching(identifier: "toolbar-record").allElementsBoundByIndex.filter(\.isHittable)
                XCTAssertEqual(records.count, 1, "Closed sidebar at \(size) must have exactly one hittable toolbar-record")

                let overflow = window.toolbars.buttons.matching(NSPredicate(format: "label CONTAINS %@ OR title CONTAINS %@", "»", "»"))
                XCTAssertEqual(overflow.count, 0, "Closed sidebar at \(size) must not show toolbar overflow (»)")
                app.terminate()
            }

            // While recording (hosted fixture): toolbar-live-pill and no toolbar-record.
            let recApp = try launchAcceptance(
                "library",
                fixture: "main",
                size: "900x720",
                dark: false,
                extra: ["--fixture-library-recording", "-CassiniCaptureID", UUID().uuidString]
            )
            defer { recApp.terminate() }
            let recWin = recApp.windows["cassini-library-window"]
            XCTAssertTrue(recWin.waitForExistence(timeout: 20), recApp.debugDescription)
            recWin.buttons["toolbar-record"].firstMatch.click()
            if recWin.sheets.buttons["record-first-start"].waitForExistence(timeout: 3) {
                recWin.sheets.buttons["record-first-start"].click()
            }
            XCTAssertTrue(recWin.descendants(matching: .any)["toolbar-live-pill"].firstMatch.waitForExistence(timeout: 10))
            _ = attachWindowScreenshot(recWin, name: "b19-item5-6-recording-900x720-light")
            XCTAssertEqual(recWin.buttons.matching(identifier: "toolbar-record").allElementsBoundByIndex.filter(\.isHittable).count, 0)
        }
    }

    /// Item 7: Floating sidebar at 900 and 560 matches docked sidebar at 1120.
    @MainActor func testFloatingSidebarMatchesDocked() throws {
        expectStrictFailure("D-1199 item 7") {
            let dockedApp = try launchAcceptance("meeting", fixture: "main", size: "1120x720", dark: false)
            defer { dockedApp.terminate() }
            let dockedWin = dockedApp.windows["cassini-library-window"]
            XCTAssertTrue(dockedWin.waitForExistence(timeout: 20), dockedApp.debugDescription)
            let dockedSearch = sidebarSearchField(in: dockedWin)
            XCTAssertTrue(dockedSearch.waitForExistence(timeout: 10))
            let dockedFilters = dockedWin.descendants(matching: .any)["library-filters"].firstMatch
            XCTAssertTrue(dockedFilters.waitForExistence(timeout: 10))

            let dockedSearchType = dockedSearch.elementType
            let dockedSearchHeight = dockedSearch.frame.height
            let dockedFilterSize = dockedFilters.frame.size
            let dockedShot = attachWindowScreenshot(dockedWin, name: "b19-item7-docked-light")
            dockedApp.terminate()

            for size in ["900x720", "560x720"] {
                let app = try launchAcceptance("meeting", fixture: "main", size: size, dark: false)
                defer { app.terminate() }
                let win = app.windows["cassini-library-window"]
                XCTAssertTrue(win.waitForExistence(timeout: 20), app.debugDescription)

                let toggle = win.buttons["floating-sidebar-toggle"].firstMatch
                if toggle.waitForExistence(timeout: 5) { toggle.click() }
                else { app.typeKey("s", modifierFlags: [.command, .control]) }

                let search = sidebarSearchField(in: win)
                XCTAssertTrue(search.waitForExistence(timeout: 10), app.debugDescription)
                let filters = win.descendants(matching: .any)["library-filters"].firstMatch
                XCTAssertTrue(filters.waitForExistence(timeout: 10))

                let floatShot = attachWindowScreenshot(win, name: "b19-item7-floating-\(size)-light")
                attachSideBySide(dockedShot, floatShot, name: "b19-item7-compare-\(size)-light")

                XCTAssertEqual(search.elementType, dockedSearchType, "Floating search field element type must match docked at \(size)")
                XCTAssertEqual(search.frame.height, dockedSearchHeight, accuracy: 0.5, "Floating search field height must match docked ±0.5 pt")
                XCTAssertEqual(filters.frame.width, dockedFilterSize.width, accuracy: 1.0)
                XCTAssertEqual(filters.frame.height, dockedFilterSize.height, accuracy: 1.0)

                let imports = win.buttons.matching(identifier: "toolbar-import").allElementsBoundByIndex.filter(\.isHittable)
                let records = win.buttons.matching(identifier: "toolbar-record").allElementsBoundByIndex.filter(\.isHittable)
                XCTAssertEqual(imports.count, 1, "Floating sidebar at \(size) must have exactly one hittable Import")
                XCTAssertEqual(records.count, 1, "Floating sidebar at \(size) must have exactly one hittable Record")
                if let imp = imports.first, let rec = records.first {
                    XCTAssertFalse(imp.frame.intersects(rec.frame), "Import and Record must not overlap")
                }

                // Esc closes the floating sidebar.
                win.typeKey(.escape, modifierFlags: [])
                XCTAssertTrue(waitFor({ !win.descendants(matching: .any)["floating-sidebar"].exists }, timeout: 5))
                app.terminate()
            }
        }
    }

    /// Item 13: Gap from Import circle right edge to Record (or live pill) left edge is 8 pt ±1.
    @MainActor func testImportRecordGap() throws {
        expectStrictFailure("D-1199 item 13") {
            let app = try launchAcceptance("library", fixture: "main", size: "1120x720", dark: false)
            defer { app.terminate() }
            let window = app.windows["cassini-library-window"]
            let importBtn = window.buttons["toolbar-import"].firstMatch
            let recordBtn = window.buttons["toolbar-record"].firstMatch
            XCTAssertTrue(importBtn.waitForExistence(timeout: 20), app.debugDescription)
            XCTAssertTrue(recordBtn.waitForExistence(timeout: 10), app.debugDescription)

            let shot = attachWindowScreenshot(window, name: "b19-item13-idle-light")
            let img = try PixelImage(screenshot: shot, windowFrame: window.frame)
            let impRect = img.windowRect(for: importBtn.frame)
            let recRect = img.windowRect(for: recordBtn.frame)
            let ground = img.color(atPoint: CGPoint(x: impRect.maxX + 4, y: impRect.midY))
            let impBounds = img.drawnHorizontalBounds(inPointRect: impRect, against: ground, threshold: 8)
            let impRight = impBounds?.right ?? impRect.maxX
            let gap = recRect.minX - impRight
            XCTAssertEqual(gap, 8.0, accuracy: 1.0, "Import-to-Record gap must be 8 pt ±1 (measured \(gap))")
        }
    }

    /// Item 14: Sidebar glass stays translucent when inactive (mean colour diff <= 4, variance not near zero).
    @MainActor func testSidebarGlassWhenInactive() throws {
        expectStrictFailure("D-1199 item 14") {
            let finder = XCUIApplication(bundleIdentifier: "com.apple.finder")
            for dark in [false, true] {
                let scheme = dark ? "dark" : "light"
                let app = try launchAcceptance("library", fixture: "main", size: "1120x720", dark: dark)
                defer { app.terminate() }
                let window = app.windows["cassini-library-window"]
                XCTAssertTrue(window.waitForExistence(timeout: 20), app.debugDescription)

                let activeShot = attachWindowScreenshot(window, name: "b19-item14-active-\(scheme)")
                let activeImg = try PixelImage(screenshot: activeShot, windowFrame: window.frame)

                finder.activate()
                let inactiveShot = attachWindowScreenshot(window, name: "b19-item14-inactive-\(scheme)")
                let inactiveImg = try PixelImage(screenshot: inactiveShot, windowFrame: window.frame)
                app.activate()

                let sampleRect = CGRect(x: 12, y: 120, width: 120, height: 180)
                let activeMean = activeImg.meanColor(inPointRect: sampleRect)
                let inactiveMean = inactiveImg.meanColor(inPointRect: sampleRect)
                let inactiveVar = inactiveImg.colorVariance(inPointRect: sampleRect)
                XCTAssertLessThanOrEqual(activeMean.maxChannelDiff(to: inactiveMean), 4.0, "Sidebar mean colour active vs inactive must differ by <= 4 (\(scheme))")
                XCTAssertGreaterThan(inactiveVar, 2.0, "Inactive sidebar must not become flat grey (variance=\(inactiveVar))")
                app.terminate()
            }
        }
    }

    /// Sidebar width: 390 pt ±2 at 1120 and 920 (meeting pane >= 520 at 920).
    @MainActor func testSidebarWidth() throws {
        expectStrictFailure("D-1199 item sidebar-width") {
            for size in ["1120x720", "920x720"] {
                let app = try launchAcceptance("meeting", fixture: "main", size: size, dark: false)
                defer { app.terminate() }
                let window = app.windows["cassini-library-window"]
                let meetingPane = window.descendants(matching: .any)["meeting-page"].firstMatch
                XCTAssertTrue(meetingPane.waitForExistence(timeout: 20), app.debugDescription)
                _ = attachWindowScreenshot(window, name: "b19-sidebar-width-\(size)-light")

                let sidebarWidth = meetingPane.frame.minX - window.frame.minX
                XCTAssertEqual(sidebarWidth, 390.0, accuracy: 2.0, "Sidebar width at \(size) must be 390 pt ±2 (measured \(sidebarWidth))")
                if size == "920x720" {
                    XCTAssertGreaterThanOrEqual(meetingPane.frame.width, 520.0, "Meeting pane at 920 must be >= 520 pt")
                }
                app.terminate()
            }
        }
    }

    /// Item 11 (live pill): toolbar-live-pill always appears reliably in sidebar toolbar across 5 scenarios x 5 iterations.
    @MainActor func testLivePillAlwaysInSidebarToolbar() throws {
        expectStrictFailure("D-1199 item 11-live-pill") {
            for size in ["1120x720", "920x720"] {
                let app = try launchAcceptance(
                    "library",
                    fixture: "main",
                    size: size,
                    dark: false,
                    extra: ["--fixture-library-recording", "-CassiniCaptureID", UUID().uuidString]
                )
                defer { app.terminate() }
                let window = app.windows["cassini-library-window"]
                let importBtn = window.buttons["toolbar-import"].firstMatch
                let recordBtn = window.buttons["toolbar-record"].firstMatch
                XCTAssertTrue(recordBtn.waitForExistence(timeout: 20), app.debugDescription)
                let idleImportFrame = importBtn.frame

                for iteration in 1...5 {
                    recordBtn.click()
                    if window.sheets.buttons["record-first-start"].waitForExistence(timeout: 2) {
                        window.sheets.buttons["record-first-start"].click()
                    }
                    let pill = window.descendants(matching: .any)["toolbar-live-pill"].firstMatch
                    XCTAssertTrue(pill.waitForExistence(timeout: 10), "toolbar-live-pill must appear (iter \(iteration), \(size))")
                    XCTAssertTrue(pill.isHittable, "toolbar-live-pill must be hittable")
                    XCTAssertGreaterThanOrEqual(pill.frame.width, 40.0, "toolbar-live-pill width >= 40 pt")
                    XCTAssertEqual(pill.frame.minX - importBtn.frame.maxX, 8.0, accuracy: 1.0, "Live pill must sit 8 pt ±1 after Import")
                    XCTAssertEqual(importBtn.frame.minX, idleImportFrame.minX, accuracy: 1.0, "Import must keep idle frame ±1")
                    if iteration == 1 {
                        _ = attachWindowScreenshot(window, name: "b19-item11-live-pill-\(size)-light")
                    }
                    window.buttons["recording-stop"].firstMatch.click()
                    XCTAssertTrue(recordBtn.waitForExistence(timeout: 10))
                }
                app.terminate()
            }
        }
    }
}
