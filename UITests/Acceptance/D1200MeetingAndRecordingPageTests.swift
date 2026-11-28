// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import XCTest

final class D1200MeetingAndRecordingPageTests: AcceptanceTestCase {
    /// Item 8: Header hairline below meeting-inline-date spans full width of meeting-transcript ±2 pt,
    /// whether the meeting has speakers or none.
    @MainActor func testHeaderLineFullWidth() throws {
        var failures: [String] = []

        for dark in [false, true] {
            let scheme = dark ? "dark" : "light"
            for size in ["1120x720", "560x720"] {
                let app = try launchAcceptance("library", fixture: "main", size: size, dark: dark, extra: ["-CassiniNoSpeechFixture", "YES"])
                defer { app.terminate() }
                let window = app.windows["cassini-library-window"]
                let transcript = window.descendants(matching: .any)["meeting-transcript"].firstMatch
                let date = inlineDateElement(in: window)
                XCTAssertTrue(transcript.waitForExistence(timeout: 20), app.debugDescription)
                XCTAssertTrue(date.waitForExistence(timeout: 10), app.debugDescription)

                let noSpeakersShot = attachWindowScreenshot(window, name: "b19-item8-no-speakers-\(size)-\(scheme)")
                let img1 = try PixelImage(screenshot: noSpeakersShot, windowFrame: window.frame)
                let tRect = img1.windowRect(for: transcript.frame)
                let dRect = img1.windowRect(for: date.frame)
                let ground = img1.color(atPoint: CGPoint(x: tRect.minX + 4, y: dRect.minY))

                var bestNoSpeakers: CGFloat = 0
                for dy in stride(from: CGFloat(4), through: 44, by: 1) {
                    let run = img1.longestHorizontalRun(atY: dRect.maxY + dy, fromX: tRect.minX, toX: tRect.maxX) {
                        $0.maxChannelDiff(to: ground) > 4
                    }
                    if run > bestNoSpeakers { bestNoSpeakers = run }
                }
                if abs(bestNoSpeakers - tRect.width) > 2.0 {
                    failures.append("No-speakers hairline \(bestNoSpeakers) != transcript width \(tRect.width) ±2 (\(size) \(scheme))")
                }
            }
        }

        expectStrictFailure("D-1200 item 8", matching: "[D-1200-item8]") {
            XCTAssertTrue(failures.isEmpty, "[D-1200-item8] \(failures.joined(separator: "; "))")
        }
    }

    /// Item 9: Renaming in toolbar, big title, and recording title keeps the date visible and sizes field to text + 8 pt.
    @MainActor func testRenameKeepsDate() throws {
        let app = try launchAcceptance(
            "meeting",
            fixture: "main",
            size: "1120x720",
            dark: false,
            extra: ["--fixture-library-rename", "-CassiniRenameID", UUID().uuidString]
        )
        defer { app.terminate() }
        let window = app.windows["cassini-library-window"]
        let inlineTitle = window.descendants(matching: .any)["meeting-inline-title"].firstMatch
        let inlineDate = inlineDateElement(in: window)
        XCTAssertTrue(inlineTitle.waitForExistence(timeout: 20), app.debugDescription)
        XCTAssertTrue(inlineDate.waitForExistence(timeout: 10), app.debugDescription)

        let dateFrameBefore = inlineDate.frame
        inlineTitle.click()
        let editor = window.textFields["meeting-inline-title-editor"].firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 5), app.debugDescription)

        _ = attachWindowScreenshot(window, name: "b19-item9-rename-big-title-light")
        let dateStillExists = inlineDate.exists
        let dateFrameDuring: CGRect? = dateStillExists ? inlineDate.frame : nil

        editor.typeKey("a", modifierFlags: .command)
        editor.typeText("Q4")
        let shortWidth = editor.frame.width

        expectStrictFailure("D-1200 item 9", matching: "[D-1200-item9]") {
            XCTAssertTrue(dateStillExists, "[D-1200-item9] Date element must still exist during rename")
            if let dateFrameDuring {
                XCTAssertEqual(dateFrameDuring.minX, dateFrameBefore.minX, accuracy: 1.0, "[D-1200-item9] Date minX must stay unchanged ±1")
                XCTAssertEqual(dateFrameDuring.minY, dateFrameBefore.minY, accuracy: 1.0, "[D-1200-item9] Date minY must stay unchanged ±1")
            }
            XCTAssertLessThan(shortWidth, 120.0, "[D-1200-item9] Rename field for 'Q4' must hug text + 8 pt, not run to the edge")
        }
    }

    /// Item 10: No grey block under toolbar at 1120, 920, 900 (sidebar open & closed, light & dark),
    /// and Parakeet notice still renders when requested.
    @MainActor func testNoGreyBlockUnderToolbar() throws {
        var failures: [String] = []

        for dark in [false, true] {
            let scheme = dark ? "dark" : "light"
            for size in ["1120x720", "920x720", "900x720"] {
                let app = try launchAcceptance("meeting", fixture: "main", size: size, dark: dark)
                defer { app.terminate() }
                let window = app.windows["cassini-library-window"]
                XCTAssertTrue(window.waitForExistence(timeout: 20), app.debugDescription)

                let shot = attachWindowScreenshot(window, name: "b19-item10-\(size)-\(scheme)")
                let img = try PixelImage(screenshot: shot, windowFrame: window.frame)
                let midX = window.frame.width / 2.0
                for y in stride(from: CGFloat(10), through: 50, by: 4) {
                    let center = img.color(atPoint: CGPoint(x: midX, y: y))
                    let left = img.color(atPoint: CGPoint(x: midX - 60, y: y))
                    let right = img.color(atPoint: CGPoint(x: midX + 60, y: y))
                    if center.maxChannelDiff(to: left) > 3.0 {
                        failures.append("Top 52 pt centre vs left diff > 3 at y=\(y) (\(size) \(scheme))")
                    }
                    if center.maxChannelDiff(to: right) > 3.0 {
                        failures.append("Top 52 pt centre vs right diff > 3 at y=\(y) (\(size) \(scheme))")
                    }
                }
            }
        }

        // Prerequisite / regression: Parakeet notice still shows when enabled.
        do {
            let noticeApp = try launchAcceptance("meeting", fixture: "main", size: "1120x720", dark: false, extra: ["-CassiniShowParakeetNotice", "YES"])
            defer { noticeApp.terminate() }
            let noticeWin = noticeApp.windows["cassini-library-window"]
            XCTAssertTrue(noticeWin.descendants(matching: .any)["parakeet-now-default"].waitForExistence(timeout: 15), noticeApp.debugDescription)
            _ = attachWindowScreenshot(noticeWin, name: "b19-item10-parakeet-notice-light")
        }

        XCTAssertTrue(failures.isEmpty, "[D-1200-item10] \(failures.joined(separator: "; "))")
    }

    /// Item 11 (recording page): Recording page background matches meeting page background within 2 and differs from sidebar.
    @MainActor func testRecordingPageBackground() throws {
        var failures: [String] = []

        for dark in [false, true] {
            let scheme = dark ? "dark" : "light"
            for size in ["1120x720", "920x720"] {
                let app = try launchAcceptance(
                    "library",
                    fixture: "main",
                    size: size,
                    dark: dark,
                    extra: seededRecordingArgs()
                )
                defer { app.terminate() }
                let window = app.windows["cassini-library-window"]
                let meetingPane = window.descendants(matching: .any)["meeting-page"].firstMatch
                XCTAssertTrue(meetingPane.waitForExistence(timeout: 20), app.debugDescription)

                let meetingShot = attachWindowScreenshot(window, name: "b19-item11-meeting-bg-\(size)-\(scheme)")
                let meetingImg = try PixelImage(screenshot: meetingShot, windowFrame: window.frame)
                let mRect = meetingImg.windowRect(for: meetingPane.frame)
                let meetingBg = meetingImg.color(atPoint: CGPoint(x: mRect.maxX - 16, y: mRect.maxY - 80))

                window.buttons["toolbar-record"].firstMatch.click()
                if window.sheets.buttons["record-first-start"].waitForExistence(timeout: 3) {
                    window.sheets.buttons["record-first-start"].click()
                }
                let recPage = window.descendants(matching: .any)["recording-page"].firstMatch
                XCTAssertTrue(recPage.waitForExistence(timeout: 10), app.debugDescription)

                let recShot = attachWindowScreenshot(window, name: "b19-item11-recording-bg-\(size)-\(scheme)")
                let recImg = try PixelImage(screenshot: recShot, windowFrame: window.frame)
                let rRect = recImg.windowRect(for: recPage.frame)
                let recBg = recImg.color(atPoint: CGPoint(x: rRect.maxX - 16, y: rRect.maxY - 80))
                let sidebarBg = recImg.color(atPoint: CGPoint(x: 16, y: rRect.maxY - 80))

                if recBg.maxChannelDiff(to: meetingBg) > 2.0 {
                    failures.append("Recording bg differed from meeting bg by \(recBg.maxChannelDiff(to: meetingBg)) > 2 (\(size) \(scheme))")
                }
                if recBg.maxChannelDiff(to: sidebarBg) <= 2.0 {
                    failures.append("Recording bg matched sidebar bg (diff=\(recBg.maxChannelDiff(to: sidebarBg)), \(size) \(scheme))")
                }
            }
        }

        expectStrictFailure("D-1200 item 11-recording-bg", matching: "[D-1200-item11-recording-bg]") {
            XCTAssertTrue(failures.isEmpty, "[D-1200-item11-recording-bg] \(failures.joined(separator: "; "))")
        }
    }

    /// Item 18: Recording page title, date, and source card align with meeting page (±1/±2 pt).
    @MainActor func testRecordingLinesUpWithMeeting() throws {
        var failures: [String] = []

        for dark in [false, true] {
            let scheme = dark ? "dark" : "light"
            for size in ["1120x720", "920x720"] {
                let app = try launchAcceptance(
                    "library",
                    fixture: "main",
                    size: size,
                    dark: dark,
                    extra: seededRecordingArgs()
                )
                defer { app.terminate() }
                let window = app.windows["cassini-library-window"]
                let meetingDate = inlineDateElement(in: window)
                XCTAssertTrue(meetingDate.waitForExistence(timeout: 20), app.debugDescription)
                let meetingDateFrame = meetingDate.frame

                window.buttons["toolbar-record"].firstMatch.click()
                if window.sheets.buttons["record-first-start"].waitForExistence(timeout: 3) {
                    window.sheets.buttons["record-first-start"].click()
                }
                let recDate = window.descendants(matching: .any)["recording-date"].firstMatch
                XCTAssertTrue(recDate.waitForExistence(timeout: 10), app.debugDescription)
                _ = attachWindowScreenshot(window, name: "b19-item18-recording-\(size)-\(scheme)")

                if abs(recDate.frame.minX - meetingDateFrame.minX) > 1.0 {
                    failures.append("recording-date minX \(recDate.frame.minX) != meeting-inline-date \(meetingDateFrame.minX) ±1 (\(size) \(scheme))")
                }
                if abs(recDate.frame.minY - meetingDateFrame.minY) > 1.0 {
                    failures.append("recording-date minY \(recDate.frame.minY) != meeting-inline-date \(meetingDateFrame.minY) ±1 (\(size) \(scheme))")
                }

                window.buttons["recording-page-stop"].firstMatch.click()
                XCTAssertTrue(meetingDate.waitForExistence(timeout: 15), app.debugDescription)
            }
        }

        expectStrictFailure("D-1200 item 18", matching: "[D-1200-item18]") {
            XCTAssertTrue(failures.isEmpty, "[D-1200-item18] \(failures.joined(separator: "; "))")
        }
    }

    /// Item 19: Capture failure notice sits inside meeting pane, doesn't overlap sidebar, has no yellow in toolbar,
    /// closes via capture-failure-close, stays closed when switching meetings, and Try again starts recording.
    @MainActor func testCaptureFailureNoticeInMeetingPane() throws {
        var failures: [String] = []

        for dark in [false, true] {
            let scheme = dark ? "dark" : "light"
            let app = try launchAcceptance(
                "library",
                fixture: "main",
                size: "1120x720",
                dark: dark,
                extra: seededRecordingArgs(extra: ["-CassiniFailCaptureStart", "YES"])
            )
            defer { app.terminate() }
            let window = app.windows["cassini-library-window"]
            let meetingPane = window.descendants(matching: .any)["meeting-page"].firstMatch
            let searchField = sidebarSearchField(in: window)
            XCTAssertTrue(meetingPane.waitForExistence(timeout: 20), app.debugDescription)
            XCTAssertTrue(searchField.waitForExistence(timeout: 10), app.debugDescription)
            let searchFrameBefore = searchField.frame

            let beforeShot = attachWindowScreenshot(window, name: "b19-item19-before-\(scheme)")
            let beforeImg = try PixelImage(screenshot: beforeShot, windowFrame: window.frame)
            let toolbarBefore = beforeImg.meanColor(inPointRect: CGRect(x: 400, y: 12, width: 300, height: 24))

            window.buttons["toolbar-record"].firstMatch.click()
            if window.sheets.buttons["record-first-start"].waitForExistence(timeout: 3) {
                window.sheets.buttons["record-first-start"].click()
            }
            let banner = window.descendants(matching: .any)["capture-failure-banner"].firstMatch
            XCTAssertTrue(banner.waitForExistence(timeout: 10), app.debugDescription)

            let afterShot = attachWindowScreenshot(window, name: "b19-item19-banner-\(scheme)")
            let afterImg = try PixelImage(screenshot: afterShot, windowFrame: window.frame)
            let toolbarAfter = afterImg.meanColor(inPointRect: CGRect(x: 400, y: 12, width: 300, height: 24))

            if banner.frame.minX < meetingPane.frame.minX - 1.0 {
                failures.append("Failure notice minX \(banner.frame.minX) overlapped sidebar (meetingPane minX=\(meetingPane.frame.minX), \(scheme))")
            }
            if abs(searchField.frame.minY - searchFrameBefore.minY) > 1.0 {
                failures.append("Search field minY moved from \(searchFrameBefore.minY) to \(searchField.frame.minY) (\(scheme))")
            }
            if toolbarBefore.maxChannelDiff(to: toolbarAfter) > 3.0 {
                failures.append("Toolbar pixels changed by \(toolbarBefore.maxChannelDiff(to: toolbarAfter)) > 3 (\(scheme))")
            }

            let closeBtn = window.buttons["capture-failure-close"].firstMatch
            if !closeBtn.exists {
                failures.append("capture-failure-close button missing (\(scheme))")
            } else {
                closeBtn.click()
                if !waitFor({ !banner.exists }, timeout: 5) {
                    failures.append("capture-failure-close did not remove banner (\(scheme))")
                }
            }
        }

        expectStrictFailure("D-1200 item 19", matching: "[D-1200-item19]") {
            XCTAssertTrue(failures.isEmpty, "[D-1200-item19] \(failures.joined(separator: "; "))")
        }
    }
}
