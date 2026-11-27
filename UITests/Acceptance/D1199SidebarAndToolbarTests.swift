// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import XCTest

final class D1199SidebarAndToolbarTests: AcceptanceTestCase {
    /// Items 5 and 6: Closed sidebar toolbar has no hittable Import, exactly one Record, no overflow (»),
    /// and shows toolbar-live-pill (with no Record) while recording.
    @MainActor func testClosedSidebarToolbar() throws {
        var failures: [String] = []

        for size in ["1120x720", "900x720", "560x720"] {
            let app = try launchAcceptance("meeting", fixture: "main", size: size, dark: false)
            defer { app.terminate() }
            let window = app.windows["cassini-library-window"]
            XCTAssertTrue(window.waitForExistence(timeout: 20), app.debugDescription)

            if size == "1120x720" {
                app.typeKey("s", modifierFlags: [.command, .control])
            }
            _ = attachWindowScreenshot(window, name: "b19-item5-6-closed-\(size)-light")

            let imports = window.buttons.matching(identifier: "toolbar-import").allElementsBoundByIndex.filter(\.isHittable)
            if imports.count != 0 {
                failures.append("Closed sidebar at \(size) had \(imports.count) hittable toolbar-import")
            }

            let records = window.buttons.matching(identifier: "toolbar-record").allElementsBoundByIndex.filter(\.isHittable)
            if records.count != 1 {
                failures.append("Closed sidebar at \(size) had \(records.count) hittable toolbar-record (expected 1)")
            }

            let overflow = window.toolbars.buttons.matching(NSPredicate(format: "label CONTAINS %@ OR title CONTAINS %@", "»", "»"))
            if overflow.count != 0 {
                failures.append("Closed sidebar at \(size) showed toolbar overflow (»)")
            }
        }

        // While recording (hosted fixture): toolbar-live-pill and no toolbar-record.
        do {
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
            let recordBtn = recWin.buttons["toolbar-record"].firstMatch
            XCTAssertTrue(recordBtn.waitForExistence(timeout: 10), recApp.debugDescription)
            recordBtn.click()
            if recWin.sheets.buttons["record-first-start"].waitForExistence(timeout: 3) {
                recWin.sheets.buttons["record-first-start"].click()
            }
            let pillAppeared = recWin.descendants(matching: .any)["toolbar-live-pill"].firstMatch.waitForExistence(timeout: 10)
            _ = attachWindowScreenshot(recWin, name: "b19-item5-6-recording-900x720-light")
            if !pillAppeared {
                failures.append("Closed sidebar while recording at 900x720 did not show toolbar-live-pill")
            }
            let recCount = recWin.buttons.matching(identifier: "toolbar-record").allElementsBoundByIndex.filter(\.isHittable).count
            if recCount != 0 {
                failures.append("Closed sidebar while recording at 900x720 still showed \(recCount) hittable toolbar-record")
            }
        }

        expectStrictFailure("D-1199 items 5 and 6", matching: "[D-1199-items5-6]") {
            XCTAssertTrue(failures.isEmpty, "[D-1199-items5-6] \(failures.joined(separator: "; "))")
        }
    }

    /// Item 7: Floating sidebar at 900 and 560 matches docked sidebar at 1120.
    @MainActor func testFloatingSidebarMatchesDocked() throws {
        var failures: [String] = []

        let dockedSearchType: XCUIElement.ElementType
        let dockedSearchHeight: CGFloat
        let dockedFilterSize: CGSize
        let dockedShot: XCUIScreenshot
        do {
            let dockedApp = try launchAcceptance("meeting", fixture: "main", size: "1120x720", dark: false)
            defer { dockedApp.terminate() }
            let dockedWin = dockedApp.windows["cassini-library-window"]
            XCTAssertTrue(dockedWin.waitForExistence(timeout: 20), dockedApp.debugDescription)
            let dockedSearch = sidebarSearchField(in: dockedWin)
            XCTAssertTrue(dockedSearch.waitForExistence(timeout: 10), dockedApp.debugDescription)
            let dockedFilters = dockedWin.descendants(matching: .any)["library-filters"].firstMatch
            XCTAssertTrue(dockedFilters.waitForExistence(timeout: 10), dockedApp.debugDescription)

            dockedSearchType = dockedSearch.elementType
            dockedSearchHeight = dockedSearch.frame.height
            dockedFilterSize = dockedFilters.frame.size
            dockedShot = attachWindowScreenshot(dockedWin, name: "b19-item7-docked-light")
        }

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
            XCTAssertTrue(filters.waitForExistence(timeout: 10), app.debugDescription)

            let floatShot = attachWindowScreenshot(win, name: "b19-item7-floating-\(size)-light")
            attachSideBySide(dockedShot, floatShot, name: "b19-item7-compare-\(size)-light")

            if search.elementType != dockedSearchType {
                failures.append("Floating search field type \(search.elementType) != docked \(dockedSearchType) at \(size)")
            }
            if abs(search.frame.height - dockedSearchHeight) > 0.5 {
                failures.append("Floating search height \(search.frame.height) != docked \(dockedSearchHeight) ±0.5 at \(size)")
            }
            if abs(filters.frame.width - dockedFilterSize.width) > 1.0 || abs(filters.frame.height - dockedFilterSize.height) > 1.0 {
                failures.append("Floating filters size \(filters.frame.size) != docked \(dockedFilterSize) ±1 at \(size)")
            }

            let imports = win.buttons.matching(identifier: "toolbar-import").allElementsBoundByIndex.filter(\.isHittable)
            let records = win.buttons.matching(identifier: "toolbar-record").allElementsBoundByIndex.filter(\.isHittable)
            if imports.count != 1 {
                failures.append("Floating sidebar at \(size) had \(imports.count) hittable Import (expected 1)")
            }
            if records.count != 1 {
                failures.append("Floating sidebar at \(size) had \(records.count) hittable Record (expected 1)")
            }
            if let imp = imports.first, let rec = records.first, imp.frame.intersects(rec.frame) {
                failures.append("Import and Record overlapped at \(size)")
            }

            win.typeKey(.escape, modifierFlags: [])
            if !waitFor({ !win.descendants(matching: .any)["floating-sidebar"].exists }, timeout: 5) {
                failures.append("Esc did not close floating sidebar at \(size)")
            }
        }

        expectStrictFailure("D-1199 item 7", matching: "[D-1199-item7]") {
            XCTAssertTrue(failures.isEmpty, "[D-1199-item7] \(failures.joined(separator: "; "))")
        }
    }

    /// Item 13: Gap from Import circle right edge to Record (or live pill) left edge is 8 pt ±1.
    @MainActor func testImportRecordGap() throws {
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

        expectStrictFailure("D-1199 item 13", matching: "[D-1199-item13]") {
            XCTAssertEqual(gap, 8.0, accuracy: 1.0, "[D-1199-item13] Import-to-Record gap must be 8 pt ±1 (measured \(gap))")
        }
    }

    /// Item 14: Sidebar glass stays translucent when inactive (mean colour diff <= 4, variance not near zero).
    @MainActor func testSidebarGlassWhenInactive() throws {
        let finder = XCUIApplication(bundleIdentifier: "com.apple.finder")
        var failures: [String] = []

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
            let diff = activeMean.maxChannelDiff(to: inactiveMean)
            if diff > 4.0 {
                failures.append("Sidebar mean colour diff \(diff) > 4 active vs inactive (\(scheme))")
            }
            if inactiveVar <= 2.0 {
                failures.append("Inactive sidebar became flat grey (variance=\(inactiveVar), \(scheme))")
            }
        }

        expectStrictFailure("D-1199 item 14", matching: "[D-1199-item14]") {
            XCTAssertTrue(failures.isEmpty, "[D-1199-item14] \(failures.joined(separator: "; "))")
        }
    }

    /// Sidebar width: 390 pt ±2 at 1120 and 920 (meeting pane >= 520 at 920).
    @MainActor func testSidebarWidth() throws {
        var failures: [String] = []

        for size in ["1120x720", "920x720"] {
            let app = try launchAcceptance("meeting", fixture: "main", size: size, dark: false)
            defer { app.terminate() }
            let window = app.windows["cassini-library-window"]
            let meetingPane = window.descendants(matching: .any)["meeting-page"].firstMatch
            XCTAssertTrue(meetingPane.waitForExistence(timeout: 20), app.debugDescription)
            _ = attachWindowScreenshot(window, name: "b19-sidebar-width-\(size)-light")

            let sidebarWidth = meetingPane.frame.minX - window.frame.minX
            if abs(sidebarWidth - 390.0) > 2.0 {
                failures.append("Sidebar width at \(size) was \(sidebarWidth), expected 390 ±2")
            }
            if size == "920x720" && meetingPane.frame.width < 520.0 {
                failures.append("Meeting pane width at 920 was \(meetingPane.frame.width), expected >= 520")
            }
        }

        expectStrictFailure("D-1199 item sidebar-width", matching: "[D-1199-sidebar-width]") {
            XCTAssertTrue(failures.isEmpty, "[D-1199-sidebar-width] \(failures.joined(separator: "; "))")
        }
    }

    /// Item 11 (live pill): toolbar-live-pill always appears reliably in sidebar toolbar across
    /// all 5 D-1195 scenarios x 5 iterations at 1120x720 and 920x720.
    @MainActor func testLivePillAlwaysInSidebarToolbar() throws {
        let finder = XCUIApplication(bundleIdentifier: "com.apple.finder")
        var failures: [String] = []

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
            let cards = window.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "meeting-card-"))
            XCTAssertTrue(recordBtn.waitForExistence(timeout: 20), app.debugDescription)
            XCTAssertTrue(importBtn.waitForExistence(timeout: 10), app.debugDescription)
            XCTAssertTrue(waitFor({ cards.count >= 2 }, timeout: 10), "Expected at least 2 meeting cards")

            let sidebarToggle = window.toolbars.buttons.matching(
                NSPredicate(format: "identifier CONTAINS[c] %@ OR label CONTAINS[c] %@", "Sidebar", "Sidebar")
            ).firstMatch
            let idleImportFrame = importBtn.frame
            let idleSidebarFrame = sidebarToggle.exists ? sidebarToggle.frame : nil

            func dismissRecordFirstSheetIfNeeded() {
                if window.sheets.buttons["record-first-start"].waitForExistence(timeout: 2) {
                    window.sheets.buttons["record-first-start"].click()
                }
            }

            func stopRecording() {
                let stopBtn = window.buttons["recording-stop"].firstMatch
                let pageStopBtn = window.buttons["recording-page-stop"].firstMatch
                if stopBtn.exists && stopBtn.isHittable {
                    stopBtn.click()
                } else if pageStopBtn.exists && pageStopBtn.isHittable {
                    pageStopBtn.click()
                } else {
                    let pill = window.descendants(matching: .any)["toolbar-live-pill"].firstMatch
                    if pill.exists && pill.isHittable {
                        pill.click()
                    }
                    if stopBtn.waitForExistence(timeout: 5) {
                        stopBtn.click()
                    } else if pageStopBtn.waitForExistence(timeout: 5) {
                        pageStopBtn.click()
                    }
                }
                XCTAssertTrue(recordBtn.waitForExistence(timeout: 10), "toolbar-record should return after stopping (\(size))")
            }

            func checkLivePill(scenario: String, iteration: Int) {
                let pill = window.descendants(matching: .any)["toolbar-live-pill"].firstMatch
                if !pill.waitForExistence(timeout: 10) {
                    failures.append("toolbar-live-pill missing (\(scenario) iter \(iteration) \(size))")
                    return
                }
                if !pill.isHittable {
                    failures.append("toolbar-live-pill not hittable (\(scenario) iter \(iteration) \(size))")
                }
                if pill.frame.width < 40.0 {
                    failures.append("toolbar-live-pill width \(pill.frame.width) < 40 (\(scenario) iter \(iteration) \(size))")
                }
                let gap = pill.frame.minX - importBtn.frame.maxX
                if abs(gap - 8.0) > 1.0 {
                    failures.append("Live pill gap \(gap) != 8 ±1 after Import (\(scenario) iter \(iteration) \(size))")
                }
                if abs(importBtn.frame.minX - idleImportFrame.minX) > 1.0 || abs(importBtn.frame.minY - idleImportFrame.minY) > 1.0 {
                    failures.append("Import button moved from idle frame \(idleImportFrame) to \(importBtn.frame) (\(scenario) iter \(iteration) \(size))")
                }
                if let expectedSidebar = idleSidebarFrame, sidebarToggle.exists {
                    if abs(sidebarToggle.frame.minX - expectedSidebar.minX) > 1.0 || abs(sidebarToggle.frame.minY - expectedSidebar.minY) > 1.0 {
                        failures.append("Sidebar button moved from idle frame \(expectedSidebar) to \(sidebarToggle.frame) (\(scenario) iter \(iteration) \(size))")
                    }
                }
            }

            for iteration in 1...5 {
                // Scenario 1: start and stop twice from toolbar-record.
                for sub in 1...2 {
                    recordBtn.click()
                    dismissRecordFirstSheetIfNeeded()
                    checkLivePill(scenario: "start-stop-\(sub)", iteration: iteration)
                    if iteration == 1 && sub == 1 {
                        _ = attachWindowScreenshot(window, name: "b19-item11-live-pill-\(size)-light")
                    }
                    stopRecording()
                }

                // Scenario 2: start with another meeting open.
                cards.element(boundBy: 1).click()
                recordBtn.click()
                dismissRecordFirstSheetIfNeeded()
                checkLivePill(scenario: "start-other-meeting", iteration: iteration)
                stopRecording()

                // Scenario 3: switch meetings while recording.
                recordBtn.click()
                dismissRecordFirstSheetIfNeeded()
                checkLivePill(scenario: "switch-before", iteration: iteration)
                cards.element(boundBy: 0).click()
                checkLivePill(scenario: "switch-to-0", iteration: iteration)
                cards.element(boundBy: 1).click()
                checkLivePill(scenario: "switch-to-1", iteration: iteration)
                stopRecording()

                // Scenario 4: close and reopen the sidebar while recording.
                recordBtn.click()
                dismissRecordFirstSheetIfNeeded()
                checkLivePill(scenario: "sidebar-before-close", iteration: iteration)
                app.typeKey("s", modifierFlags: [.command, .control])
                app.typeKey("s", modifierFlags: [.command, .control])
                XCTAssertTrue(importBtn.waitForExistence(timeout: 10), "toolbar-import must reappear after reopening sidebar")
                checkLivePill(scenario: "sidebar-reopened", iteration: iteration)
                stopRecording()

                // Scenario 5: ⌘R with Finder active.
                finder.activate()
                app.typeKey("r", modifierFlags: .command)
                dismissRecordFirstSheetIfNeeded()
                checkLivePill(scenario: "cmd-r-finder-active", iteration: iteration)
                stopRecording()
            }
        }

        expectStrictFailure("D-1199 item 11-live-pill", matching: "[D-1199-item11-live-pill]") {
            XCTAssertTrue(failures.isEmpty, "[D-1199-item11-live-pill] \(failures.joined(separator: "; "))")
        }
    }
}
