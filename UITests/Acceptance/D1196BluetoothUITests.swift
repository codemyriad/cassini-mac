// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import XCTest

final class D1196BluetoothUITests: AcceptanceTestCase {
    @MainActor func testFailedTranscriptionShowsNeedsAttention() throws {
        expectStrictFailure("D-1196 item 5") {
            let extra = [
                "--fixture-library-recording",
                "-CassiniCaptureID", UUID().uuidString,
                "-CassiniTranscriptionFixture", "YES",
                "-CassiniFailTranscriptionOnce", "YES",
            ]
            let app = try launchAcceptance("first-run", fixture: "empty", size: "1120x720", dark: false, extra: extra)
            defer { app.terminate() }

            let window = app.windows["cassini-library-window"]
            XCTAssertTrue(window.buttons["first-run-record"].waitForExistence(timeout: 20), app.debugDescription)
            window.buttons["first-run-record"].click()
            XCTAssertTrue(window.sheets.buttons["record-first-start"].waitForExistence(timeout: 10), app.debugDescription)
            window.sheets.buttons["record-first-start"].click()
            XCTAssertTrue(window.buttons["recording-stop"].waitForExistence(timeout: 10), app.debugDescription)

            // Wait for a few seconds of fixture speech to be recorded, then stop.
            let recorded = waitFor({
                let timer = window.staticTexts["recording-big-timer"]
                guard timer.exists else { return false }
                let parts = self.visibleText(timer).split(separator: ":").compactMap { Int($0) }
                guard parts.count == 3 else { return false }
                return parts[0] * 3600 + parts[1] * 60 + parts[2] >= 2
            }, timeout: 10)
            XCTAssertTrue(recorded, "Fixture recording should advance timer")
            window.buttons["recording-stop"].click()

            // Wait for transcription to start or fail, then assert within 2 s of failure
            // the sidebar row shows "Needs attention", the meeting shows "Try again", and transcribing-status is gone.
            let retry = window.buttons["Try again"]
            XCTAssertTrue(retry.waitForExistence(timeout: 20), "Meeting should show Try again after failed transcription")

            let settled = waitFor({
                let needsAttention = window.staticTexts.matching(NSPredicate(format: "value CONTAINS[c] %@ OR label CONTAINS[c] %@", "Needs attention", "Needs attention")).firstMatch.exists
                let transcribingGone = !window.descendants(matching: .any)["transcribing-status"].exists
                return needsAttention && retry.exists && transcribingGone
            }, timeout: 2.0)

            _ = attachWindowScreenshot(window, name: "b19-d1196-needs-attention-light")
            XCTAssertTrue(settled, "Within 2 s of failure, row must show Needs attention, meeting must show Try again, and transcribing-status must be gone")
        }
    }
}
