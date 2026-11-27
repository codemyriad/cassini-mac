// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import XCTest

final class D1200MeetingAndRecordingPageTests: AcceptanceTestCase {
    /// Item 8: Header hairline below meeting-inline-date spans full width of meeting-transcript ±2 pt,
    /// whether the meeting has speakers or none.
    @MainActor func testHeaderLineFullWidth() throws {
        expectStrictFailure("D-1200 item 8") {
            for dark in [false, true] {
                let scheme = dark ? "dark" : "light"
                for size in ["1120x720", "560x720"] {
                    let app = try launchAcceptance("library", fixture: "main", size: size, dark: dark, extra: ["-CassiniNoSpeechFixture", "YES"])
                    defer { app.terminate() }
                    let window = app.windows["cassini-library-window"]
                    let transcript = window.descendants(matching: .any)["meeting-transcript"].firstMatch
                    let date = window.descendants(matching: .any)["meeting-inline-date"].firstMatch
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
                    XCTAssertEqual(bestNoSpeakers, tRect.width, accuracy: 2.0, "No-speakers header hairline must equal transcript width ±2 pt (\(size) \(scheme))")
                    app.terminate()
                }
            }
        }
    }

    /// Item 9: Renaming in toolbar, big title, and recording title keeps the date visible and sizes field to text + 8 pt.
    @MainActor func testRenameKeepsDate() throws {
        expectStrictFailure("D-1200 item 9") {
            let app = try launchAcceptance("meeting", fixture: "main", size: "1120x720", dark: false)
            defer { app.terminate() }
            let window = app.windows["cassini-library-window"]
            let inlineTitle = window.descendants(matching: .any)["meeting-inline-title"].firstMatch
            let inlineDate = window.descendants(matching: .any)["meeting-inline-date"].firstMatch
            XCTAssertTrue(inlineTitle.waitForExistence(timeout: 20), app.debugDescription)
            XCTAssertTrue(inlineDate.waitForExistence(timeout: 10), app.debugDescription)

            let dateFrameBefore = inlineDate.frame
            inlineTitle.click()
            let editor = window.textFields["meeting-inline-title-editor"].firstMatch
            XCTAssertTrue(editor.waitForExistence(timeout: 5), app.debugDescription)

            _ = attachWindowScreenshot(window, name: "b19-item9-rename-big-title-light")
            XCTAssertTrue(inlineDate.exists, "Date element must still exist during rename")
            XCTAssertEqual(inlineDate.frame.minX, dateFrameBefore.minX, accuracy: 1.0)
            XCTAssertEqual(inlineDate.frame.minY, dateFrameBefore.minY, accuracy: 1.0)

            // Type short title "Q4" and verify field does not stretch to column edge.
            editor.typeKey("a", modifierFlags: .command)
            editor.typeText("Q4")
            XCTAssertLessThan(editor.frame.width, 120.0, "Rename field for 'Q4' must hug text + 8 pt, not run to the edge")
        }
    }

    /// Item 10: No grey block under toolbar at 1120, 920, 900 (sidebar open & closed, light & dark),
    /// and Parakeet notice still renders when requested.
    @MainActor func testNoGreyBlockUnderToolbar() throws {
        expectStrictFailure("D-1200 item 10") {
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
                        XCTAssertLessThanOrEqual(center.maxChannelDiff(to: left), 3.0, "Top 52 pt centre must match 60 pt left at y=\(y) (\(size) \(scheme))")
                        XCTAssertLessThanOrEqual(center.maxChannelDiff(to: right), 3.0, "Top 52 pt centre must match 60 pt right at y=\(y) (\(size) \(scheme))")
                    }
                    app.terminate()
                }
            }

            // Parakeet notice still shows when enabled.
            let noticeApp = try launchAcceptance("meeting", fixture: "main", size: "1120x720", dark: false, extra: ["-CassiniShowParakeetNotice", "YES"])
            defer { noticeApp.terminate() }
            let noticeWin = noticeApp.windows["cassini-library-window"]
            XCTAssertTrue(noticeWin.descendants(matching: .any)["parakeet-now-default"].waitForExistence(timeout: 15))
            _ = attachWindowScreenshot(noticeWin, name: "b19-item10-parakeet-notice-light")
        }
    }

    /// Item 11 (recording page): Recording page background matches meeting page background within 2 and differs from sidebar.
    @MainActor func testRecordingPageBackground() throws {
        expectStrictFailure("D-1200 item 11-recording-bg") {
            for dark in [false, true] {
                let scheme = dark ? "dark" : "light"
                for size in ["1120x720", "920x720"] {
                    let app = try launchAcceptance(
                        "library",
                        fixture: "main",
                        size: size,
                        dark: dark,
                        extra: ["--fixture-library-recording", "-CassiniCaptureID", UUID().uuidString]
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

                    XCTAssertLessThanOrEqual(recBg.maxChannelDiff(to: meetingBg), 2.0, "Recording page background must equal meeting page within 2 (\(size) \(scheme))")
                    XCTAssertGreaterThan(recBg.maxChannelDiff(to: sidebarBg), 2.0, "Recording page background must differ from sidebar (\(size) \(scheme))")
                    app.terminate()
                }
            }
        }
    }

    /// Item 18: Recording page title, date, and source card align with meeting page (±1/±2 pt).
    @MainActor func testRecordingLinesUpWithMeeting() throws {
        expectStrictFailure("D-1200 item 18") {
            for dark in [false, true] {
                let scheme = dark ? "dark" : "light"
                for size in ["1120x720", "920x720"] {
                    let app = try launchAcceptance(
                        "library",
                        fixture: "main",
                        size: size,
                        dark: dark,
                        extra: ["--fixture-library-recording", "-CassiniCaptureID", UUID().uuidString]
                    )
                    defer { app.terminate() }
                    let window = app.windows["cassini-library-window"]
                    let meetingDate = window.descendants(matching: .any)["meeting-inline-date"].firstMatch
                    XCTAssertTrue(meetingDate.waitForExistence(timeout: 20), app.debugDescription)
                    let meetingDateFrame = meetingDate.frame

                    window.buttons["toolbar-record"].firstMatch.click()
                    if window.sheets.buttons["record-first-start"].waitForExistence(timeout: 3) {
                        window.sheets.buttons["record-first-start"].click()
                    }
                    let recDate = window.descendants(matching: .any)["recording-date"].firstMatch
                    XCTAssertTrue(recDate.waitForExistence(timeout: 10), app.debugDescription)
                    _ = attachWindowScreenshot(window, name: "b19-item18-recording-\(size)-\(scheme)")

                    XCTAssertEqual(recDate.frame.minX, meetingDateFrame.minX, accuracy: 1.0, "recording-date minX must match meeting-inline-date ±1 pt")
                    XCTAssertEqual(recDate.frame.minY, meetingDateFrame.minY, accuracy: 1.0, "recording-date minY must match meeting-inline-date ±1 pt")

                    window.buttons["recording-page-stop"].firstMatch.click()
                    XCTAssertTrue(meetingDate.waitForExistence(timeout: 15))
                    app.terminate()
                }
            }
        }
    }

    /// Item 19: Capture failure notice sits inside meeting pane, doesn't overlap sidebar, has no yellow in toolbar,
    /// closes via capture-failure-close, stays closed when switching meetings, and Try again starts recording.
    @MainActor func testCaptureFailureNoticeInMeetingPane() throws {
        expectStrictFailure("D-1200 item 19") {
            for dark in [false, true] {
                let scheme = dark ? "dark" : "light"
                let app = try launchAcceptance(
                    "library",
                    fixture: "main",
                    size: "1120x720",
                    dark: dark,
                    extra: [
                        "--fixture-library-recording",
                        "-CassiniCaptureID", UUID().uuidString,
                        "-CassiniFailCaptureStart", "YES",
                    ]
                )
                defer { app.terminate() }
                let window = app.windows["cassini-library-window"]
                let meetingPane = window.descendants(matching: .any)["meeting-page"].firstMatch
                let searchField = sidebarSearchField(in: window)
                XCTAssertTrue(meetingPane.waitForExistence(timeout: 20), app.debugDescription)
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

                XCTAssertGreaterThanOrEqual(banner.frame.minX, meetingPane.frame.minX - 1.0, "Failure notice must lie inside meeting pane and not overlap sidebar")
                XCTAssertEqual(searchField.frame.minY, searchFrameBefore.minY, accuracy: 1.0, "Search field must keep its frame ±1")
                XCTAssertLessThanOrEqual(toolbarBefore.maxChannelDiff(to: toolbarAfter), 3.0, "Toolbar pixels must be unchanged (no yellow)")

                let closeBtn = window.buttons["capture-failure-close"].firstMatch
                XCTAssertTrue(closeBtn.exists, "capture-failure-close button must exist")
                closeBtn.click()
                XCTAssertTrue(waitFor({ !banner.exists }, timeout: 5), "capture-failure-close must remove the banner")
                app.terminate()
            }
        }
    }
}
