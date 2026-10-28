// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import XCTest

final class LibraryBoards: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        try XCTSkipUnless(ProcessInfo.processInfo.environment["CASSINI_HOSTED_SCREENSHOTS"] == "1" && ProcessInfo.processInfo.environment["CASSINI_LIBRARY_BOARDS"] == "1", "Hosted-only Library boards")
    }
    @MainActor func testLibrary() throws { try board("library", fixture: "main") }
    @MainActor func testFirstRun() throws { try board("first-run", fixture: "empty") }
    @MainActor func testSearchBoardFiltersAndOpeningTheHit() throws {
        let app = try launch("search",fixture:"main"); defer { app.terminate() }
        let window = app.windows["cassini-library-window"], count = window.staticTexts["search-count"]
        XCTAssertTrue(count.waitForExistence(timeout:20),window.debugDescription)
        let ready = NSPredicate { _,_ in self.visibleText(count) == "4 places in 3 meetings" }
        XCTAssertEqual(XCTWaiter.wait(for:[XCTNSPredicateExpectation(predicate:ready,object:nil)],timeout:10),.completed)
        XCTAssertFalse(window.buttons["Has summary"].exists)
        XCTAssertTrue(window.buttons["search-play"].exists)
        capture(window,name:"search")
        window.descendants(matching:.any).matching(identifier:"search-date").firstMatch.click()
        app.menuItems["Today"].click()
        let today = NSPredicate { _,_ in self.visibleText(count) == "2 places in 1 meeting" }
        XCTAssertEqual(XCTWaiter.wait(for:[XCTNSPredicateExpectation(predicate:today,object:nil)],timeout:5),.completed)
        window.descendants(matching:.any).matching(identifier:"search-date").firstMatch.click(); app.menuItems["Any date"].click()
        window.descendants(matching:.any).matching(identifier:"search-speaker").firstMatch.click(); app.menuItems["Dario"].click()
        let noHits = NSPredicate { _,_ in self.visibleText(count) == "0 places in 0 meetings" }
        XCTAssertEqual(XCTWaiter.wait(for:[XCTNSPredicateExpectation(predicate:noHits,object:nil)],timeout:5),.completed)
        window.descendants(matching:.any).matching(identifier:"search-speaker").firstMatch.click(); app.menuItems["Marta"].click()
        XCTAssertEqual(XCTWaiter.wait(for:[XCTNSPredicateExpectation(predicate:ready,object:nil)],timeout:5),.completed)
        let hit = window.buttons.matching(NSPredicate(format:"identifier CONTAINS %@",":4:0")).firstMatch
        XCTAssertTrue(hit.exists); hit.click()
        window.buttons["search-open-meeting"].click()
        XCTAssertTrue(window.buttons["meeting-back"].waitForExistence(timeout:5))
        XCTAssertTrue(text("00:14:32",in:window),window.debugDescription)
        app.typeKey("f",modifierFlags:.command)
        XCTAssertTrue(window.searchFields["library-search-field"].waitForExistence(timeout:5))
        XCTAssertEqual(window.searchFields["library-search-field"].value as? String,"")
        // Cmd-F must focus the newly attached native field without a mouse click.
        app.typeText("budget")
        XCTAssertEqual(window.searchFields["library-search-field"].value as? String,"budget")
        app.typeKey(.escape,modifierFlags:[])
        XCTAssertTrue(window.buttons["preview-play"].waitForExistence(timeout:5),window.debugDescription)
    }
    @MainActor func testReceivedBoard() throws {
        let app = try launch("received",fixture:"received-only"); defer { app.terminate() }
        let window = app.windows["cassini-library-window"]
        XCTAssertTrue(window.descendants(matching:.any).matching(identifier:"received-folder-card").firstMatch.waitForExistence(timeout:20),window.debugDescription)
        XCTAssertTrue(window.buttons["preview-play"].isEnabled)
        XCTAssertTrue(text("Record your own meetings with the button above.",in:window))
        capture(window,name:"received")
    }
    @MainActor func testExportBoardAndKeyboardChoices() throws {
        let app = try launch("export",fixture:"main"); defer { app.terminate() }
        let window = app.windows["cassini-library-window"], sheet = window.sheets.firstMatch
        XCTAssertTrue(sheet.buttons["export-confirm"].waitForExistence(timeout:20),app.debugDescription)
        XCTAssertEqual(sheet.frame.width,540,accuracy:2)
        XCTAssertEqual(selected(sheet.radioButtons["Cassini file"]),true)
        XCTAssertFalse(sheet.radioButtons["Markdown"].isSelected)
        capture(window,name:"export")
        sheet.radioButtons["Markdown"].click()
        XCTAssertEqual(selected(sheet.radioButtons["Markdown"]),true)
        app.typeKey(.escape,modifierFlags:[])
        let dismissed = NSPredicate { _,_ in !sheet.exists }
        XCTAssertEqual(XCTWaiter.wait(for:[XCTNSPredicateExpectation(predicate:dismissed,object:nil)],timeout:5),.completed,app.debugDescription)
        app.typeKey("e",modifierFlags:[.command,.shift])
        XCTAssertTrue(sheet.buttons["export-confirm"].waitForExistence(timeout:5))
        XCTAssertEqual(selected(sheet.radioButtons["Cassini file"]),true)
        sheet.buttons["export-confirm"].click()
        // NSSavePanel is exposed as a sheet on some supported macOS versions.
        XCTAssertTrue(app.buttons["Save"].waitForExistence(timeout:10),app.debugDescription)
        // Exercise the actual per-file Powerbox grant, outside the app's
        // container, so publication cannot rely on a folder-wide test grant.
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("CassiniPanelExport-" + UUID().uuidString)
        try FileManager.default.createDirectory(at:destination,withIntermediateDirectories:false)
        defer { try? FileManager.default.removeItem(at:destination) }
        app.typeKey("g",modifierFlags:[.command,.shift])
        app.typeText(destination.path); app.typeKey(.return,modifierFlags:[])
        app.buttons["Save"].click()
        let output = destination.appendingPathComponent("Budget review.opus")
        let saved = NSPredicate { _,_ in FileManager.default.fileExists(atPath:output.path) }
        XCTAssertEqual(XCTWaiter.wait(for:[XCTNSPredicateExpectation(predicate:saved,object:nil)],timeout:20),.completed,app.debugDescription)
        let bytes = try Data(contentsOf:output)
        XCTAssertEqual(bytes.prefix(4),Data("OggS".utf8))
        XCTAssertNotNil(bytes.range(of:Data("CASSINI_FORMAT=org.cassini.portable-meeting/1".utf8)))
    }
    @MainActor func testRecordingBoard() throws {
        let app = try launch("recording",fixture:"main"); defer { app.terminate() }
        let window = app.windows["cassini-library-window"]
        XCTAssertTrue(window.textFields["recording-title"].waitForExistence(timeout:20),app.debugDescription)
        XCTAssertTrue(text("00:12:48",in:window))
        XCTAssertTrue(text("Recording since 14:05 · saved as it records",in:window))
        XCTAssertTrue(text("Listening inside your browser · 4 voices",in:window))
        XCTAssertTrue(text("No sound from your microphone. Check your sound settings.",in:window))
        XCTAssertTrue(window.buttons["recording-check-microphone"].exists)
        XCTAssertFalse(window.buttons["Change what is recorded"].isEnabled)
        let exact = NSPredicate { _,_ in abs(window.frame.width - 1120) < 0.1 && abs(window.frame.height - 720) < 0.1 }
        XCTAssertEqual(XCTWaiter.wait(for:[XCTNSPredicateExpectation(predicate:exact,object:nil)],timeout:10),.completed)
        capture(window,name:"recording")
    }
    @MainActor func testRecordingTitleNotesAndHiddenControls() throws {
        let app = try launch("first-run",fixture:"empty",extra:["--fixture-library-recording","-CassiniCaptureID",UUID().uuidString])
        defer { app.terminate() }
        let window = app.windows["cassini-library-window"]
        XCTAssertTrue(window.buttons["first-run-record"].waitForExistence(timeout:20))
        window.buttons["first-run-record"].click()
        XCTAssertTrue(window.sheets.buttons["record-first-start"].waitForExistence(timeout:10))
        window.sheets.checkBoxes["Don’t show again"].click()
        window.sheets.buttons["record-first-start"].click()
        let title = window.textFields["recording-title"]
        XCTAssertTrue(title.waitForExistence(timeout:10),app.debugDescription)
        title.click(); app.typeKey("a",modifierFlags:.command); title.typeText("Title from the live page")
        let notes = window.textViews["recording-notes"]
        notes.click(); notes.typeText("A note to keep")
        window.buttons.matching(identifier:"recording-back").firstMatch.click()
        window.buttons["recording-open-current"].click()
        XCTAssertTrue(title.waitForExistence(timeout:10))
        XCTAssertEqual(title.value as? String,"Title from the live page")
        XCTAssertTrue((notes.value as? String ?? "").contains("A note to keep"))
        app.typeKey("h",modifierFlags:.command)
        let status = app.descendants(matching:.any)["recording-menu-bar"]
        XCTAssertTrue(status.waitForExistence(timeout:10),app.debugDescription); status.click()
        let payload = app.staticTexts["recording-menu-fixture-payload"]
        XCTAssertTrue(payload.waitForExistence(timeout:10),app.debugDescription)
        let json = try XCTUnwrap(payload.value as? String)
        let data = try XCTUnwrap(json.data(using:.utf8))
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with:data) as? [String:Any])
        XCTAssertEqual(body["assertionHeld"] as? Bool,true)
        XCTAssertEqual(body["title"] as? String,"Title from the live page")
        XCTAssertEqual(body["noSleep"] as? String,"Your Mac will not sleep while Cassini records.")
        let actions = try XCTUnwrap(body["actions"] as? [[String:Any]])
        XCTAssertEqual(actions.compactMap { $0["id"] as? String },["stop","note","open"])
        XCTAssertEqual(actions.first?["shortcut"] as? String,"⌥⌘R")
        let dump = XCTAttachment(data:data,uniformTypeIdentifier:"public.json")
        dump.name = "recording-menu.json"; dump.lifetime = .keepAlways; add(dump)
        app.buttons["recording-menu-note"].click()
        XCTAssertTrue(notes.waitForExistence(timeout:10))
        notes.typeText("\nFrom the hidden menu")
        app.typeKey("h",modifierFlags:.command)
        let finder = XCUIApplication(bundleIdentifier:"com.apple.finder"); finder.activate()
        finder.typeKey("r",modifierFlags:[.option,.command])
        app.activate()
        let saved = NSPredicate { _,_ in window.buttons["preview-play"].exists && window.buttons["preview-play"].isEnabled }
        XCTAssertEqual(XCTWaiter.wait(for:[XCTNSPredicateExpectation(predicate:saved,object:nil)],timeout:15),.completed,app.debugDescription)
        XCTAssertFalse(window.buttons["recording-stop"].exists)
        // Start from another app too; persisted first-record consent is reused.
        app.typeKey("h",modifierFlags:.command); finder.activate()
        finder.typeKey("r",modifierFlags:[.option,.command]); app.activate()
        XCTAssertTrue(window.buttons["recording-stop"].waitForExistence(timeout:10),app.debugDescription)
        XCTAssertFalse(window.sheets.firstMatch.exists)
        window.buttons["recording-stop"].click()
    }
    @MainActor func testRecordFirstBoard() throws {
        let app = try launch("record-first", fixture: "first-record"); defer { app.terminate() }
        let window = app.windows["cassini-library-window"]
        XCTAssertTrue(window.sheets.staticTexts["Before your first recording"].waitForExistence(timeout: 20), app.debugDescription)
        XCTAssertTrue(window.sheets.checkBoxes["Don’t show again"].exists)
        XCTAssertTrue(window.sheets.buttons["record-first-start"].exists)
        XCTAssertTrue(text("macOS asks you to allow this next.", in: window.sheets.firstMatch))
        XCTAssertTrue(text("macOS asks once more, for Screen & System Audio Recording.", in: window.sheets.firstMatch))
        let explanation = window.sheets.staticTexts["Cassini also records the sound of your meeting apps so the other participants are on the recording."]
        XCTAssertTrue(explanation.exists)
        XCTAssertGreaterThan(explanation.frame.height, 28, "The complete explanation must wrap, rather than truncate")
        XCTAssertEqual(window.toolbars.staticTexts.matching(NSPredicate(format: "value == %@ OR label == %@", "Library", "Library")).count, 1)
        capture(window, name: "record-first")
        XCTAssertEqual(window.frame.width, 1120, accuracy: 0.1)
        XCTAssertEqual(window.frame.height, 720, accuracy: 0.1)
        window.sheets.buttons["Not now"].click()
        XCTAssertFalse(window.buttons["recording-stop"].exists)
    }
    @MainActor func testCaptureWritesIntoLibraryAndSaves() throws {
        let id = UUID().uuidString
        let app = try launch("first-run", fixture: "empty", extra: ["--fixture-library-recording", "-CassiniCaptureID", id])
        defer { app.terminate() }
        let window = app.windows["cassini-library-window"]
        XCTAssertTrue(window.buttons["first-run-record"].waitForExistence(timeout: 20), app.debugDescription)
        window.buttons["first-run-record"].click()
        XCTAssertTrue(window.sheets.buttons["record-first-start"].waitForExistence(timeout: 10))
        window.sheets.buttons["record-first-start"].click()
        XCTAssertTrue(window.buttons["recording-stop"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(app.windows.count, 1)
        XCTAssertFalse(app.windows["open-panel"].exists)
        let mic = window.progressIndicators["recording-microphone-meter"]
        let output = window.progressIndicators["recording-others-meter"]
        func value(_ meter: XCUIElement) -> Double {
            (meter.value as? NSNumber)?.doubleValue ?? Double(meter.value as? String ?? "") ?? .nan
        }
        let meterReady = NSPredicate { _, _ in abs(value(mic) - 0.12) < 0.005 && abs(value(output) - 0.38) < 0.005 }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: meterReady, object: nil)], timeout: 5), .completed, window.debugDescription)
        window.buttons["recording-stop"].click()
        XCTAssertTrue(window.staticTexts["Saving…"].waitForExistence(timeout: 5), window.debugDescription)
        let saved = NSPredicate { _, _ in window.buttons["preview-play"].exists && window.buttons["preview-play"].isEnabled && !window.staticTexts["Saving…"].exists }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: saved, object: nil)], timeout: 10), .completed, window.debugDescription)
        XCTAssertFalse(window.buttons["recording-stop"].exists)
        XCTAssertFalse(app.windows["open-panel"].exists)
    }
    @MainActor func testRecordFirstPreferenceSurvivesRelaunch() throws {
        let extra = ["--fixture-library-recording", "-CassiniCaptureID", UUID().uuidString]
        var app = try launch("first-run", fixture: "empty", extra: extra)
        defer { if app.state != .notRunning { app.terminate() } }
        var window = app.windows["cassini-library-window"]
        XCTAssertTrue(window.buttons["first-run-record"].waitForExistence(timeout: 20))
        window.buttons["first-run-record"].click()
        let checkbox = window.sheets.checkBoxes["Don’t show again"]
        XCTAssertTrue(checkbox.waitForExistence(timeout: 10)); checkbox.click()
        window.sheets.buttons["Not now"].click()
        app.terminate()
        app = try launch("first-run", fixture: "empty", extra: extra)
        window = app.windows["cassini-library-window"]
        XCTAssertTrue(window.buttons["first-run-record"].waitForExistence(timeout: 20))
        app.typeKey("r", modifierFlags: .command)
        XCTAssertTrue(window.buttons["recording-stop"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertFalse(window.sheets.firstMatch.exists)
        app.typeKey("r", modifierFlags: .command)
        let saved = NSPredicate { _, _ in window.buttons["preview-play"].exists && window.buttons["preview-play"].isEnabled && !window.staticTexts["Saving…"].exists }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: saved, object: nil)], timeout: 10), .completed)
    }
    @MainActor func testDiskReserveStopsAndKeepsTheRecording() throws {
        let extra = ["--fixture-library-recording", "-CassiniCaptureID", UUID().uuidString,
                     "-CassiniDiskFree", "1073741824", "-CassiniDiskTotal", "10000000000"]
        let app = try launch("first-run", fixture: "empty", extra: extra); defer { app.terminate() }
        let window = app.windows["cassini-library-window"]
        XCTAssertTrue(window.buttons["first-run-record"].waitForExistence(timeout: 20), app.debugDescription)
        window.buttons["first-run-record"].click()
        XCTAssertTrue(window.sheets.staticTexts["Only 0 minutes of space left."].waitForExistence(timeout: 10))
        XCTAssertFalse(window.sheets.buttons["Choose another folder"].exists)
        window.sheets.buttons["record-first-start"].click()
        let line = "Cassini stopped recording to keep some space free on this computer. Everything up to now is saved."
        XCTAssertTrue(window.staticTexts[line].waitForExistence(timeout: 10), app.debugDescription)
        let saved = NSPredicate { _, _ in window.buttons["preview-play"].exists && window.buttons["preview-play"].isEnabled && !window.staticTexts["Saving…"].exists }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: saved, object: nil)], timeout: 10), .completed)
        XCTAssertFalse(window.buttons["recording-stop"].exists)
    }
    @MainActor func testStopWritesDownAndRetryKeepsAudio() throws {
        let extra = ["--fixture-library-recording", "-CassiniCaptureID", UUID().uuidString,
                     "-CassiniTranscriptionFixture", "YES", "-CassiniFailTranscriptionOnce", "YES"]
        let app = try launch("first-run", fixture: "empty", extra: extra); defer { app.terminate() }
        let window = app.windows["cassini-library-window"]
        XCTAssertTrue(window.buttons["first-run-record"].waitForExistence(timeout: 20), app.debugDescription)
        window.buttons["first-run-record"].click()
        XCTAssertTrue(window.sheets.buttons["record-first-start"].waitForExistence(timeout: 10))
        window.sheets.buttons["record-first-start"].click()
        XCTAssertTrue(window.buttons["recording-stop"].waitForExistence(timeout: 10), app.debugDescription)
        let speech = NSPredicate { _, _ in self.recordedSeconds(window) >= 5 }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: speech, object: nil)], timeout: 10), .completed)
        window.buttons["recording-stop"].click()
        let retry = window.buttons["Try again"]
        XCTAssertTrue(retry.waitForExistence(timeout: 20), app.debugDescription)
        XCTAssertTrue(text("Could not write this meeting down. The audio is fine.", in: window))
        XCTAssertTrue(window.buttons["preview-play"].isEnabled)
        retry.click()
        let readable = NSPredicate { _, _ in window.buttons["preview-read-transcript"].isEnabled && !retry.exists }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: readable, object: nil)], timeout: 40), .completed, app.debugDescription)
        window.buttons["preview-read-transcript"].click()
        XCTAssertTrue(window.buttons["meeting-back"].waitForExistence(timeout: 10))
        XCTAssertTrue(text("Me", in: window), app.debugDescription)
        XCTAssertFalse(window.buttons["meeting-write-down"].exists)
    }
    @MainActor func testQuitPausesWritingDownAndResumesOnRelaunch() throws {
        let base = ["--fixture-library-recording", "-CassiniCaptureID", UUID().uuidString, "-CassiniTranscriptionFixture", "YES"]
        var app = try launch("first-run",fixture:"empty",extra:base + ["-CassiniSlowTranscription","YES"])
        defer { if app.state != .notRunning { app.terminate() } }
        var window = app.windows["cassini-library-window"]
        XCTAssertTrue(window.buttons["first-run-record"].waitForExistence(timeout:20),app.debugDescription)
        window.buttons["first-run-record"].click()
        XCTAssertTrue(window.sheets.buttons["record-first-start"].waitForExistence(timeout:10))
        window.sheets.buttons["record-first-start"].click()
        XCTAssertTrue(window.buttons["recording-stop"].waitForExistence(timeout:10))
        let speech = NSPredicate { _,_ in self.recordedSeconds(window) >= 5 }
        XCTAssertEqual(XCTWaiter.wait(for:[XCTNSPredicateExpectation(predicate:speech,object:nil)],timeout:10),.completed)
        window.buttons["recording-stop"].click()
        XCTAssertTrue(window.staticTexts["Transcribing…"].waitForExistence(timeout:10),app.debugDescription)
        app.typeKey("q",modifierFlags:.command)
        let exited = NSPredicate { _,_ in app.state == .notRunning }
        XCTAssertEqual(XCTWaiter.wait(for:[XCTNSPredicateExpectation(predicate:exited,object:nil)],timeout:5),.completed)
        app = try launch("first-run",fixture:"empty",extra:base)
        window = app.windows["cassini-library-window"]
        let resumed = NSPredicate { _,_ in window.buttons["preview-read-transcript"].exists && window.buttons["preview-read-transcript"].isEnabled }
        XCTAssertEqual(XCTWaiter.wait(for:[XCTNSPredicateExpectation(predicate:resumed,object:nil)],timeout:40),.completed,app.debugDescription)
        XCTAssertFalse(window.buttons["Try again"].exists)
        XCTAssertTrue(window.buttons["preview-play"].isEnabled)
    }
    @MainActor func testMeetingBoard() throws {
        let app = try launch("meeting", fixture: "main"); defer { app.terminate() }
        let window = app.windows["cassini-library-window"]
        XCTAssertTrue(window.buttons["meeting-back"].waitForExistence(timeout: 20), app.debugDescription)
        XCTAssertTrue(window.staticTexts["meeting-elapsed"].waitForExistence(timeout: 10))
        let title = window.staticTexts["meeting-title"]
        XCTAssertTrue(title.waitForExistence(timeout: 5), window.debugDescription)
        XCTAssertTrue(title.isHittable, window.debugDescription)
        XCTAssertTrue(text("Client call, Rossi & Partners", in: window))
        XCTAssertTrue(text("Today, 11:30 · 47 min", in: window))
        XCTAssertEqual(title.frame.minX - window.frame.minX, 280, accuracy: 16)
        capture(window, name: "meeting")
        for value in ["43%", "36%", "21%", "00:03:12", "00:47:05", "Named by you", "Recognised from saved voices", "Not named yet"] { XCTAssertTrue(text(value, in: window), value) }
        XCTAssertFalse(window.buttons["Name the speakers"].exists)
        XCTAssertFalse(window.buttons["Inspector"].exists)
        XCTAssertEqual(window.frame.width, 1120, accuracy: 0.1)
        XCTAssertEqual(window.frame.height, 720, accuracy: 0.1)
        window.buttons["Forward 10 seconds"].click()
        XCTAssertTrue(text("00:03:22", in: window))
        window.buttons["Back 10 seconds"].click()
        XCTAssertTrue(text("00:03:12", in: window))
    }
    @MainActor func testTranscriptCanBeClosedAndReopened() throws {
        let app = try launch("library", fixture: "main"); defer { app.terminate() }
        let library = app.windows["cassini-library-window"]
        for _ in 0..<3 {
            let read = library.buttons["preview-read-transcript"]
            XCTAssertTrue(read.waitForExistence(timeout: 20)); read.click()
            XCTAssertTrue(library.buttons["meeting-back"].waitForExistence(timeout: 10))
            XCTAssertEqual(app.windows.count, 1)
            library.buttons["meeting-back"].click()
            XCTAssertTrue(read.waitForExistence(timeout: 10))
        }
    }
    @MainActor func testOpenAndFinderRoutingWithLibraryClosed() async throws {
        let app = try launch("first-run", fixture: "empty",extra:["--fixture-library-recording","-CassiniCaptureID",UUID().uuidString]); defer { app.terminate() }
        let library = app.windows["cassini-library-window"]
        XCTAssertTrue(library.waitForExistence(timeout: 20))
        library.buttons["_XCUI:CloseWindow"].click()
        let closed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: library)
        XCTAssertEqual(XCTWaiter.wait(for: [closed], timeout: 5), .completed)
        app.typeKey("o", modifierFlags: .command)
        XCTAssertTrue(app.windows["open-panel"].waitForExistence(timeout: 5), app.debugDescription)
        app.typeKey(.escape, modifierFlags: [])
        let cancelled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.windows["open-panel"])
        XCTAssertEqual(XCTWaiter.wait(for: [cancelled], timeout: 5), .completed)
        XCTAssertFalse(library.exists)
        let fixture = try fixtureDirectory().appendingPathComponent("meeting.opus")
        for _ in 0..<2 {
            try await finderOpen(fixture)
            XCTAssertTrue(library.buttons["preview-read-transcript"].waitForExistence(timeout: 15), app.debugDescription)
            XCTAssertTrue(library.descendants(matching:.any)["received-folder-card"].exists)
            XCTAssertEqual(app.windows.count, 1)
        }
        library.buttons["_XCUI:CloseWindow"].click()
        let closedAgain = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: library)
        XCTAssertEqual(XCTWaiter.wait(for: [closedAgain], timeout: 5), .completed)
        try await finderOpen(fixture)
        XCTAssertTrue(library.buttons["preview-read-transcript"].waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertEqual(app.windows.count, 1)
    }
    @MainActor func testReceivedReadAndPlayReuseOneViewer() throws {
        let app = try launch("library", fixture: "main"); defer { app.terminate() }
        let library = app.windows["cassini-library-window"]
        let received = library.descendants(matching: .any).matching(identifier: "meeting-Received-a0000000-0000-4000-8000-000000000006").firstMatch
        XCTAssertTrue(received.waitForExistence(timeout: 20), app.debugDescription)
        received.click()
        let selectedReceived = NSPredicate { _,_ in self.text("Onboarding walkthrough",in:library) && library.descendants(matching:.any).matching(identifier:"received-folder-card").firstMatch.exists }
        XCTAssertEqual(XCTWaiter.wait(for:[XCTNSPredicateExpectation(predicate:selectedReceived,object:nil)],timeout:5),.completed,library.debugDescription)
        library.buttons["preview-read-transcript"].click()
        XCTAssertTrue(library.buttons["meeting-back"].waitForExistence(timeout: 15))
        XCTAssertEqual(app.windows.count, 1)
        library.buttons["meeting-back"].click()
        XCTAssertTrue(library.buttons["preview-play"].waitForExistence(timeout: 10))
        library.buttons["preview-play"].click()
        XCTAssertTrue(library.buttons["meeting-back"].waitForExistence(timeout: 15))
        XCTAssertEqual(app.windows.count, 1)
    }
    @MainActor func testSuggestionDismissalPersistsAcrossNavigation() throws {
        let app = try launch("library", fixture: "main"); defer { app.terminate() }
        let window = app.windows["cassini-library-window"]
        XCTAssertTrue(window.buttons["preview-read-transcript"].waitForExistence(timeout: 20))
        window.buttons["preview-read-transcript"].click()
        XCTAssertTrue(window.buttons["Not now"].waitForExistence(timeout: 10))
        window.buttons["Not now"].click()
        window.buttons["meeting-back"].click()
        window.buttons["preview-read-transcript"].click()
        XCTAssertFalse(window.buttons["Not now"].exists)
    }
    @MainActor func testCloseAndQuitConfirmationKeyboardRoles() throws {
        let app = try launch("first-run", fixture: "empty", extra: ["--fixture-recording-active"])
        defer { if app.state != .notRunning { app.terminate() } }
        let window = app.windows["cassini-library-window"]
        XCTAssertTrue(window.waitForExistence(timeout: 20))
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(window.sheets.staticTexts["A recording is running"].waitForExistence(timeout: 10))
        app.typeKey(.escape, modifierFlags: [])
        let cancelled = NSPredicate { _, _ in window.exists && !window.sheets.firstMatch.exists }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate:cancelled,object:nil)], timeout: 5), .completed)
        app.typeKey("q", modifierFlags: .command)
        XCTAssertTrue(app.staticTexts["A recording is running"].waitForExistence(timeout: 10))
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(app.state != .notRunning)
        app.typeKey("q", modifierFlags: .command)
        XCTAssertTrue(app.staticTexts["A recording is running"].waitForExistence(timeout: 10))
        app.typeKey(.return, modifierFlags: [])
        let ended = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in app.state == .notRunning }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [ended], timeout: 10), .completed)
    }
    @MainActor func testCloseConfirmationKeepsTheWindowUntilStopAndKeepIsChosen() throws {
        let app = try launch("first-run", fixture: "empty", extra: ["--fixture-recording-active"])
        defer { if app.state != .notRunning { app.terminate() } }
        let window = app.windows["cassini-library-window"]
        XCTAssertTrue(window.waitForExistence(timeout:20))
        app.typeKey("w",modifierFlags:.command)
        XCTAssertTrue(window.sheets.buttons["Keep recording"].waitForExistence(timeout:10),app.debugDescription)
        window.sheets.buttons["Keep recording"].click()
        let kept = NSPredicate { _,_ in window.exists && !window.sheets.firstMatch.exists }
        XCTAssertEqual(XCTWaiter.wait(for:[XCTNSPredicateExpectation(predicate:kept,object:nil)],timeout:5),.completed)
        app.typeKey("w",modifierFlags:.command)
        XCTAssertTrue(window.sheets.staticTexts["A recording is running"].waitForExistence(timeout:10))
        app.typeKey(.return,modifierFlags:[])
        let closed = XCTNSPredicateExpectation(predicate:NSPredicate(format:"exists == false"),object:window)
        XCTAssertEqual(XCTWaiter.wait(for:[closed],timeout:10),.completed)
    }
    @MainActor func testFailedReadClosesLoadingViewer() throws {
        let app = XCUIApplication(); defer { app.terminate() }
        app.launchEnvironment["CASSINI_HOSTED_SCREENSHOTS"] = "1"
        // Legacy fixture routing intentionally points to a nonexistent file.
        // That mode skips the real Library scanner and never starts playback.
        let absent = try fixtureDirectory().appendingPathComponent("absent-fixture")
        app.launchArguments = ["-CassiniScreenshot", "first-run", "-CassiniFixture", try fixtureDirectory().appendingPathComponent("Library/empty").path, "-CassiniOpenFile", absent.appendingPathComponent("meeting.opus").path,
                               "-CassiniNow", "2026-10-27T13:18:00Z", "-ApplePersistenceIgnoreState", "YES",
                               "-AppleLanguages", "(en-GB)", "-AppleLocale", "en_GB"]
        app.launch()
        let okay = app.dialogs.firstMatch.buttons["OK"]
        XCTAssertTrue(okay.waitForExistence(timeout: 15), app.debugDescription)
        okay.click()
        let settled = NSPredicate { _, _ in app.progressIndicators.count == 0 && app.windows.count == 1 }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: settled, object: nil)], timeout: 10), .completed, app.debugDescription)
        XCTAssertTrue(app.windows["cassini-library-window"].exists)
    }
    @MainActor private func finderOpen(_ url: URL) async throws {
        let appURL = try fixtureDirectory().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        XCTAssertEqual(appURL.pathExtension, "app")
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        _ = try await NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: configuration)
    }
    @MainActor private func launch(_ name: String, fixture: String, extra: [String] = []) throws -> XCUIApplication {
        let app = XCUIApplication()
        let root = try fixtureDirectory().appendingPathComponent("Library/" + fixture)
        app.launchEnvironment["CASSINI_HOSTED_SCREENSHOTS"] = "1"
        app.launchArguments = ["-CassiniScreenshot", name, "-CassiniFixture", root.path,
                               "-CassiniNow", "2026-10-27T13:18:00Z", "-ApplePersistenceIgnoreState", "YES",
                               "-AppleLanguages", "(en-GB)", "-AppleLocale", "en_GB", "-AppleInterfaceStyle", "Light", "-AppleAccentColor", "4"]
        app.launchArguments += extra
        if extra.contains("--fixture-library-recording"), !extra.contains("-CassiniDiskFree") {
            app.launchArguments += ["-CassiniDiskFree",String(20 << 30),"-CassiniDiskTotal",String(100 << 30)]
        }
        app.launch()
        if extra.contains("--fixture-library-recording"), !app.windows.firstMatch.waitForExistence(timeout: 2) {
            app.menuBars.menuBarItems["Window"].click()
            app.menuBars.menuBarItems["Window"].menus.menuItems["Library"].click()
        }
        return app
    }
    @MainActor private func board(_ name: String, fixture: String) throws {
        let app = try launch(name, fixture: fixture); defer { app.terminate() }
        let window = app.windows["cassini-library-window"]
        XCTAssertTrue(window.waitForExistence(timeout: 20), app.debugDescription)
        let expectedControl = name == "library" ? "preview-read-transcript" : "first-run-record"
        XCTAssertTrue(window.buttons[expectedControl].waitForExistence(timeout: 20), window.debugDescription)
        let exactFrame = NSPredicate { _, _ in abs(window.frame.width - 1120) < 0.1 && abs(window.frame.height - 720) < 0.1 }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: exactFrame, object: nil)], timeout: 10), .completed, window.debugDescription)
        if name == "library" {
            let subtitle = window.staticTexts["preview-subtitle"]
            let ready = NSPredicate { _, _ in subtitle.exists && subtitle.isHittable && subtitle.frame.minX >= window.frame.minX + 420 }
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: ready, object: nil)], timeout: 10), .completed, window.debugDescription)
            capture(window, name: name)
            XCTAssertTrue(window.buttons["preview-read-transcript"].waitForExistence(timeout: 20), window.debugDescription)
            XCTAssertTrue(window.staticTexts.matching(NSPredicate(format: "value CONTAINS %@ OR label CONTAINS %@", "52 min · Marta, Dario, Speaker 3", "52 min · Marta, Dario, Speaker 3")).firstMatch.exists)
            XCTAssertTrue(text("Today, 09:00 · 52 min", in: window), window.debugDescription)
            XCTAssertTrue(text("00:00:04", in: window))
            XCTAssertTrue(text("Listening inside your browser", in: window))
            XCTAssertTrue(text("Your microphone and the meeting in your browser", in: window))
            XCTAssertTrue(window.buttons["preview-play"].isEnabled)
            let title = window.staticTexts["library-toolbar-title"]
            XCTAssertTrue(title.exists)
            XCTAssertEqual(title.frame.minX - window.frame.minX, 420, accuracy: 12)
        } else {
            capture(window, name: name)
            XCTAssertTrue(window.buttons["first-run-record"].waitForExistence(timeout: 20), window.debugDescription)
            XCTAssertTrue(text("Your recorded meetings will appear here.", in: window))
            XCTAssertTrue(text("Recordings and transcripts stay on this computer, in Music/Cassini.", in: window))
            let title = window.staticTexts["library-toolbar-title"]
            XCTAssertTrue(title.exists)
            XCTAssertEqual(title.frame.midX, window.frame.midX, accuracy: 20)
        }
        XCTAssertEqual(window.frame.width, 1120, accuracy: 0.1)
        XCTAssertEqual(window.frame.height, 720, accuracy: 0.1)
    }
    private func visibleText(_ element: XCUIElement) -> String {
        if let value = element.value as? String, !value.isEmpty { return value }
        return element.label
    }
    private func selected(_ element: XCUIElement) -> Bool {
        if let value = element.value as? NSNumber { return value.intValue == 1 }
        return element.value as? String == "1" || element.isSelected
    }
    private func recordedSeconds(_ window: XCUIElement) -> Int {
        let timer = window.staticTexts["recording-big-timer"]
        guard timer.exists else { return 0 }
        let values = visibleText(timer).split(separator:":").compactMap { Int($0) }
        guard values.count == 3 else { return 0 }; return values[0] * 3600 + values[1] * 60 + values[2]
    }
    private func capture(_ window: XCUIElement, name: String) {
        // Retain an exact-size, fully laid-out board even if a content check fails.
        let attachment = XCTAttachment(screenshot: window.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    private func text(_ value: String, in window: XCUIElement) -> Bool {
        window.staticTexts.matching(NSPredicate(format: "value == %@ OR label == %@", value, value)).firstMatch.exists
    }
    private func fixtureDirectory() throws -> URL {
        var ancestor = Bundle(for: Self.self).bundleURL
        for _ in 0..<8 {
            let directory = ancestor.appendingPathComponent("Cassini.app/Contents/Resources/Fixtures")
            if FileManager.default.fileExists(atPath: directory.appendingPathComponent("Library/main/activity.json").path) { return directory }
            ancestor.deleteLastPathComponent()
        }
        throw NSError(domain: "CassiniLibraryBoards", code: 1)
    }
}
