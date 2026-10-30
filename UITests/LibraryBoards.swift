// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import XCTest

final class LibraryBoards: XCTestCase {
    @MainActor func testMoveToTrashMenusAndFirstRun() throws {
        let extra = ["--fixture-library-recording","-CassiniCaptureID",UUID().uuidString]
        let app = try launch("first-run",fixture:"empty",extra:extra); defer { app.terminate() }
        let window = app.windows["cassini-library-window"]
        XCTAssertTrue(window.buttons["first-run-record"].waitForExistence(timeout:20))
        window.buttons["first-run-record"].click()
        window.sheets.buttons["record-first-start"].click()
        XCTAssertTrue(window.buttons["recording-stop"].waitForExistence(timeout:10))
        app.menuBars.menuBarItems["File"].click()
        XCTAssertFalse(app.menuItems["Move to Trash"].isEnabled,"Recording cannot be trashed")
        app.typeKey(.escape,modifierFlags:[])
        window.buttons["recording-stop"].click()
        XCTAssertTrue(window.buttons["preview-play"].waitForExistence(timeout:10))
        let row = window.descendants(matching:.any).matching(NSPredicate(format:"identifier BEGINSWITH %@","meeting-Recording-")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout:10),app.debugDescription)
        row.rightClick()
        XCTAssertTrue(app.menuItems["Export…"].exists)
        XCTAssertTrue(window.menuItems["move-to-trash"].isEnabled)
        capture(window,name:"trash")
        app.typeKey(.escape,modifierFlags:[])
        row.click()
        app.typeKey(XCUIKeyboardKey(rawValue:"\u{F70D}"),modifierFlags:.shift)
        XCTAssertTrue(app.menuItems["library-keyboard-trash"].waitForExistence(timeout:5),"Shift-F10 opens the selected row menu")
        XCTAssertTrue(app.menuItems["library-keyboard-trash"].isEnabled)
        app.typeKey(.escape,modifierFlags:[])
        app.typeKey(.delete,modifierFlags:.command)
        XCTAssertTrue(window.buttons["first-run-record"].waitForExistence(timeout:10),app.debugDescription)
        XCTAssertFalse(window.sheets.firstMatch.exists,"No confirmation")
        capture(window,name:"trash-after")
    }
    @MainActor func testMeetingTrashAndSearchKeyboardGuard() throws {
        let app = try launch("meeting",fixture:"main"); defer { app.terminate() }
        let window = app.windows["cassini-library-window"]
        let more = window.descendants(matching:.any).matching(identifier:"meeting-more-actions").firstMatch
        XCTAssertTrue(more.waitForExistence(timeout:20),app.debugDescription)
        more.click()
        XCTAssertTrue(window.menuItems["move-to-trash"].exists)
        capture(window,name:"trash-meeting")
        app.typeKey(.escape,modifierFlags:[])
        window.buttons["meeting-back"].click()
        app.typeKey("f",modifierFlags:.command)
        app.menuBars.menuBarItems["File"].click()
        XCTAssertFalse(app.menuItems["Move to Trash"].isEnabled,"Search and text focus retain delete")
        app.typeKey(.escape,modifierFlags:[])
    }
    @MainActor func testCompanionSetupBoard() throws {
        let app = try launch("meeting",fixture:"main",extra:["-CassiniCompanionBoard","YES"]); defer { app.terminate() }
        let window = app.windows["cassini-library-window"]
        let setup = window.buttons["Set up"]
        XCTAssertTrue(setup.waitForExistence(timeout:20),app.debugDescription); setup.click()
        XCTAssertTrue(window.sheets.staticTexts["Hear each person on their own"].waitForExistence(timeout:10),app.debugDescription)
        XCTAssertTrue(text("Done. Cassini is in Chrome.",in:window))
        XCTAssertFalse(window.sheets.buttons["companion-connect"].exists,"D31 setup proceeds without a Connect button")
        XCTAssertTrue(text("Setting up the connection…",in:window))
        XCTAssertFalse(window.sheets.buttons["Done"].isEnabled)
        capture(window,name:"companion-setup")
        window.sheets.buttons["Not now"].click()
        XCTAssertTrue(window.buttons["meeting-back"].exists)
    }
    @MainActor func testWhatIsRecordedBoard() throws {
        let app = try launch("recording",fixture:"main"); defer { app.terminate() }
        let window = app.windows["cassini-library-window"], change = window.buttons["recording-change-sources"]
        XCTAssertTrue(change.waitForExistence(timeout:20),app.debugDescription); change.click()
        XCTAssertTrue(window.sheets.staticTexts["What is recorded"].waitForExistence(timeout:10),app.debugDescription)
        XCTAssertTrue(window.sheets.buttons["capture-choice-me"].exists)
        XCTAssertTrue(window.sheets.buttons["capture-choice-others"].exists)
        XCTAssertTrue(window.sheets.buttons["capture-choice-both"].exists)
        XCTAssertTrue(text("Listening inside your browser",in:window))
        capture(window,name:"what-is-recorded")
        window.sheets.buttons["Done"].click()
        XCTAssertTrue(window.buttons["recording-change-sources"].exists)
    }
    @MainActor func testRenameFromFileAndWindowTitle() throws {
        let app = try launch("library",fixture:"main",extra:["--fixture-library-rename","-CassiniRenameID",UUID().uuidString])
        defer { app.terminate() }
        let window = app.windows["cassini-library-window"]
        let budget = window.staticTexts.matching(NSPredicate(format:"value == %@ OR label == %@","Budget review","Budget review")).firstMatch
        XCTAssertTrue(budget.waitForExistence(timeout:20),app.debugDescription); budget.click()
        app.menuBars.menuBarItems["File"].click(); app.menuItems["Rename…"].click()
        let field = app.textFields["rename-name"]
        XCTAssertTrue(field.waitForExistence(timeout:10),app.debugDescription)
        XCTAssertEqual(field.value as? String,"Budget review")
        XCTAssertFalse(app.buttons["rename-confirm"].isEnabled)
        field.typeText("Project review") // Initial contents must be selected.
        XCTAssertEqual(field.value as? String,"Project review")
        capture(window,name:"rename")
        app.typeKey(.return,modifierFlags:[])
        let updated = NSPredicate { _,_ in !field.exists && window.staticTexts.matching(NSPredicate(format:"value == %@ OR label == %@","Project review","Project review")).count >= 2 }
        XCTAssertEqual(XCTWaiter.wait(for:[XCTNSPredicateExpectation(predicate:updated,object:nil)],timeout:10),.completed,app.debugDescription)
        window.buttons["preview-read-transcript"].click()
        let title = window.staticTexts["meeting-title"]
        XCTAssertTrue(title.waitForExistence(timeout:10),app.debugDescription)
        title.click()
        XCTAssertTrue(field.waitForExistence(timeout:10),app.debugDescription)
        // Avoid macOS's double-space-to-period substitution while still
        // proving the UI trims both ends. Core cases cover repeated whitespace.
        field.typeText(" Board notes "); app.typeKey(.return,modifierFlags:[])
        let renamed = NSPredicate { _,_ in (title.value as? String ?? title.label) == "Board notes" && !field.exists }
        XCTAssertEqual(XCTWaiter.wait(for:[XCTNSPredicateExpectation(predicate:renamed,object:nil)],timeout:10),.completed,app.debugDescription)
        title.click(); XCTAssertTrue(field.waitForExistence(timeout:10))
        field.typeText(" "); app.typeKey(.return,modifierFlags:[])
        let blank = NSPredicate { _,_ in (title.value as? String ?? title.label) == "Untitled meeting" && !field.exists }
        XCTAssertEqual(XCTWaiter.wait(for:[XCTNSPredicateExpectation(predicate:blank,object:nil)],timeout:10),.completed,app.debugDescription)
        XCTAssertTrue(window.staticTexts["meeting-subtitle"].exists,"Untitled meetings retain their date/duration subtitle")
        title.click(); XCTAssertTrue(field.waitForExistence(timeout:10))
        XCTAssertFalse(app.buttons["rename-confirm"].isEnabled)
        field.typeText("Cancelled name"); app.typeKey(.escape,modifierFlags:[])
        let cancelled = NSPredicate { _,_ in !field.exists && (title.value as? String ?? title.label) == "Untitled meeting" }
        XCTAssertEqual(XCTWaiter.wait(for:[XCTNSPredicateExpectation(predicate:cancelled,object:nil)],timeout:10),.completed)
    }
    @MainActor func testRenameReceivedFromRowMenus() throws {
        let app = try launch("received",fixture:"received-only",extra:["--fixture-library-rename","-CassiniRenameID",UUID().uuidString])
        defer { app.terminate() }
        let window = app.windows["cassini-library-window"]
        let row = window.descendants(matching:.any).matching(NSPredicate(format:"identifier BEGINSWITH %@","meeting-Received-")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout:20),app.debugDescription)
        row.rightClick(); XCTAssertTrue(window.menuItems["library-rename"].isEnabled); window.menuItems["library-rename"].click()
        let field = app.textFields["rename-name"]
        XCTAssertTrue(field.waitForExistence(timeout:10),app.debugDescription)
        let original = field.value as? String
        field.typeText("Discarded lesson"); window.sheets.firstMatch.buttons["Cancel"].click()
        let cancelled = NSPredicate { _,_ in !field.exists }
        XCTAssertEqual(XCTWaiter.wait(for:[XCTNSPredicateExpectation(predicate:cancelled,object:nil)],timeout:10),.completed)
        row.click(); app.typeKey(XCUIKeyboardKey(rawValue:"\u{F70D}"),modifierFlags:.shift)
        XCTAssertTrue(app.menuItems["library-keyboard-rename"].waitForExistence(timeout:5),app.debugDescription)
        app.menuItems["library-keyboard-rename"].hover(); app.typeKey(.return,modifierFlags:[])
        XCTAssertTrue(field.waitForExistence(timeout:10),app.debugDescription)
        XCTAssertEqual(field.value as? String,original,"Cancel must not save when the field loses focus")
        field.typeText("Imported lesson"); app.typeKey(.return,modifierFlags:[])
        let updated = NSPredicate { _,_ in !field.exists && window.staticTexts.matching(NSPredicate(format:"value == %@ OR label == %@","Imported lesson","Imported lesson")).count >= 2 }
        XCTAssertEqual(XCTWaiter.wait(for:[XCTNSPredicateExpectation(predicate:updated,object:nil)],timeout:10),.completed,app.debugDescription)
        XCTAssertTrue(window.buttons["preview-play"].isEnabled)
    }
    @MainActor func testConsentRecognisesAnAlreadyAllowedMicrophoneAndKeepsTheAppShortcut() throws {
        let app = try launch("first-run",fixture:"empty",extra:["--fixture-library-recording","-CassiniCaptureID",UUID().uuidString,"-CassiniConsentAllowed","YES"])
        defer { app.terminate() }
        let window = app.windows["cassini-library-window"]
        XCTAssertTrue(window.buttons["first-run-record"].waitForExistence(timeout:20))
        XCTAssertTrue(text("⌘R records from anywhere in Cassini",in:window))
        XCTAssertFalse(text("⌥⌘R records from anywhere in Cassini",in:window))
        window.buttons["first-run-record"].click()
        XCTAssertTrue(window.sheets.staticTexts["Before you record"].waitForExistence(timeout:10))
        XCTAssertTrue(text("Allowed",in:window.sheets.firstMatch))
        XCTAssertFalse(text("macOS asks you to allow this next.",in:window.sheets.firstMatch))
        app.typeKey(.escape,modifierFlags:[])
        XCTAssertTrue(window.buttons["first-run-record"].exists)
        if app.menuBars.menuBarItems["Help"].exists {
            app.menuBars.menuBarItems["Help"].click()
            XCTAssertFalse(app.menuItems["Cassini Help"].exists)
            app.typeKey(.escape,modifierFlags:[])
        }
    }
    @MainActor func testBrowserStatesBeforeFirstConnectionAndAfterFailure() throws {
        for kind in ["absent","first","lost"] {
            let app = try launch("library",fixture:"main",extra:["--fixture-library-rename","-CassiniRenameID",UUID().uuidString,"-CassiniBrowserCase",kind])
            let window = app.windows["cassini-library-window"]
            XCTAssertTrue(window.buttons["preview-play"].waitForExistence(timeout:20),app.debugDescription)
            XCTAssertFalse(window.descendants(matching:.any)["capture-failure-banner"].exists)
            if kind == "lost" {
                XCTAssertTrue(window.buttons["browser-try-again"].waitForExistence(timeout:10),app.debugDescription)
                XCTAssertTrue(window.staticTexts["library-browser-status"].exists)
            } else { XCTAssertFalse(window.staticTexts["library-browser-status"].exists) }
            app.typeKey(",",modifierFlags:.command)
            let settings = app.windows["cassini-settings-window"]
            XCTAssertTrue(settings.waitForExistence(timeout:10))
            settings.toolbars.buttons["Browser companion"].click()
            if kind == "absent" {
                let add = settings.buttons["browser-add"]
                XCTAssertTrue(add.waitForExistence(timeout:10),app.debugDescription); XCTAssertFalse(add.isEnabled)
                XCTAssertTrue(text("Browser meetings need Chrome, Edge, Brave or Chromium.",in:settings))
                XCTAssertFalse(settings.buttons["browser-try-again"].exists)
                app.typeKey("w",modifierFlags:.command)
                let budget = window.staticTexts.matching(NSPredicate(format:"value == %@ OR label == %@","Budget review","Budget review")).firstMatch
                budget.click()
                XCTAssertTrue(window.buttons["preview-read-transcript"].isEnabled)
                window.buttons["preview-read-transcript"].click()
                XCTAssertTrue(window.buttons["Set up"].waitForExistence(timeout:15),app.debugDescription)
                window.buttons["Set up"].click()
                XCTAssertTrue(window.sheets.buttons["companion-add"].waitForExistence(timeout:10),app.debugDescription)
                XCTAssertFalse(window.sheets.buttons["companion-add"].isEnabled)
                XCTAssertFalse(window.sheets.buttons["companion-connect"].exists)
                XCTAssertFalse(text("Couldn’t connect.",in:window.sheets.firstMatch))
                window.sheets.buttons["Not now"].click()
            } else if kind == "first" {
                XCTAssertTrue(settings.buttons["browser-add"].waitForExistence(timeout:10)); XCTAssertTrue(settings.buttons["browser-add"].isEnabled)
                XCTAssertFalse(settings.buttons["browser-try-again"].exists)
            } else { XCTAssertTrue(settings.buttons["browser-try-again"].waitForExistence(timeout:10)) }
            app.terminate()
        }
    }
    @MainActor func testMeetingAccessibility() throws {
        let app = try launch("meeting",fixture:"main"); defer { app.terminate() }
        let window = app.windows["cassini-library-window"]
        XCTAssertTrue(window.buttons["meeting-export"].waitForExistence(timeout:20),app.debugDescription)
        let tree = XCTAttachment(string:app.debugDescription)
        tree.name = "meeting-accessibility-tree"; tree.lifetime = .keepAlways; add(tree)
        XCTAssertEqual(window.buttons["meeting-back"].label,"Back to Library")
        XCTAssertEqual(window.buttons["toolbar-record"].label,"Record")
        XCTAssertEqual(window.buttons["meeting-export"].label,"Export…")
        let more = window.buttons.matching(identifier:"meeting-more-actions")
        XCTAssertEqual(more.count,1,"Exactly one actionable More control")
        XCTAssertEqual(more.element.label,"More actions")
        XCTAssertEqual(window.sliders["meeting-seek"].label,"Position")
        XCTAssertEqual(window.sliders["meeting-seek"].value as? String,"00:03:12")
        XCTAssertEqual(window.buttons["meeting-speed"].label,"Playback speed, 1×")
        let turns = window.descendants(matching:.any).matching(NSPredicate(format:"identifier BEGINSWITH %@","meeting-turn-"))
        XCTAssertGreaterThan(turns.count,0,app.debugDescription)
        XCTAssertTrue(turns.firstMatch.label.contains("00:"))
        XCTAssertEqual(window.links.count,0,"VoiceOver sees complete turns, while pointer word links stay visual")
        XCTAssertFalse(window.descendants(matching:.any)["capture-failure-banner"].exists)
        let slider = window.sliders["meeting-seek"]
        slider.coordinate(withNormalizedOffset:CGVector(dx:0.6,dy:0.5)).click()
        let sought = NSPredicate { _,_ in
            guard let value = slider.value as? String, value != "00:03:12", value.split(separator:":").count == 3 else { return false }
            return window.staticTexts["meeting-elapsed"].value as? String == value
        }
        XCTAssertEqual(XCTWaiter.wait(for:[XCTNSPredicateExpectation(predicate:sought,object:nil)],timeout:5),.completed,"Seeking still updates playback and its accessible time")
    }
    @MainActor func testOpeningMeetingWithoutWords() throws {
        let app = try launch("library",fixture:"main",extra:["--fixture-library-rename","--fixture-library-no-words","-CassiniRenameID",UUID().uuidString]); defer { app.terminate() }
        let window = app.windows["cassini-library-window"]
        let weekly = window.outlines.staticTexts.matching(identifier:"meeting-Recording-a0000000-0000-4000-8000-000000000008").firstMatch
        XCTAssertTrue(weekly.waitForExistence(timeout:20)); weekly.click()
        XCTAssertTrue(window.buttons["preview-write-down"].waitForExistence(timeout:5),"This private copy must have no transcript before testing opening")
        XCTAssertFalse(window.buttons["preview-read-transcript"].isEnabled)
        weekly.doubleClick()
        XCTAssertTrue(window.buttons["meeting-write-down"].waitForExistence(timeout:10),app.debugDescription)
        XCTAssertTrue(window.buttons["meeting-play"].isEnabled)
        XCTAssertTrue(window.buttons["meeting-export"].isEnabled)
        app.menuBars.menuBarItems["File"].click(); XCTAssertTrue(app.menuItems["Rename…"].isEnabled); app.typeKey(.escape,modifierFlags:[])
        window.buttons["meeting-back"].click()
        let client = window.outlines.staticTexts.matching(identifier:"meeting-Recording-a0000000-0000-4000-8000-000000000002").firstMatch
        client.click(); XCTAssertTrue(window.descendants(matching:.any)["preview-transcribing"].waitForExistence(timeout:5))
        let budget = window.outlines.staticTexts.matching(identifier:"meeting-Recording-a0000000-0000-4000-8000-000000000001").firstMatch
        budget.click(); app.typeKey(.return,modifierFlags:[])
        XCTAssertTrue(window.buttons["meeting-back"].waitForExistence(timeout:10),app.debugDescription)
        XCTAssertEqual(window.staticTexts["meeting-title"].value as? String,"Budget review")
    }
    override func setUpWithError() throws {
        continueAfterFailure = false
        try XCTSkipUnless(ProcessInfo.processInfo.environment["CASSINI_HOSTED_SCREENSHOTS"] == "1" && ProcessInfo.processInfo.environment["CASSINI_LIBRARY_BOARDS"] == "1", "Hosted-only Library boards")
    }
    @MainActor func testSettingsTranscriptionModelChoices() throws {
        let app = try launch("settings-transcription",fixture:"main",extra:["-CassiniSettingsID",UUID().uuidString]); defer { app.terminate() }
        let window = app.windows["cassini-settings-window"]
        XCTAssertTrue(window.descendants(matching:.any).matching(identifier:"settings-whistle-row").firstMatch.waitForExistence(timeout:20),app.debugDescription)
        XCTAssertTrue(text("Writing down what was said",in:window))
        XCTAssertTrue(text("When Cassini uses the network",in:window))
        XCTAssertTrue(window.buttons["settings-download-parakeet"].waitForExistence(timeout:5))
        XCTAssertTrue(text("Parakeet Ultra",in:window)); XCTAssertFalse(text("Tell speakers apart",in:window))
        let parakeet = window.radioButtons["settings-parakeet-radio"]
        XCTAssertTrue(parakeet.waitForExistence(timeout:5),app.debugDescription)
        XCTAssertFalse(parakeet.isEnabled)
        let whistle = window.radioButtons["settings-whistle-radio"]
        XCTAssertTrue(whistle.exists && whistle.isEnabled)
        XCTAssertEqual(String(describing:try XCTUnwrap(whistle.value)),"1")
        XCTAssertTrue(text("443 MB download",in:window))
        XCTAssertFalse(text("To check for updates. No meeting data is sent.",in:window))
        capture(window,name:"settings-transcription")
    }
    @MainActor func testSettingsRecordingPreferenceAndTabs() throws {
        let app = try launch("settings-recording",fixture:"main",extra:["-CassiniSettingsID",UUID().uuidString]); defer { app.terminate() }
        let window = app.windows["cassini-settings-window"]
        let toggle = window.descendants(matching:.any).matching(identifier:"settings-explain-recording")
            .matching(NSPredicate(format:"value != nil")).firstMatch
        XCTAssertTrue(window.buttons["settings-change-shortcut"].waitForExistence(timeout:20),app.debugDescription)
        capture(window,name:"settings-recording")
        XCTAssertTrue(toggle.waitForExistence(timeout:5),app.debugDescription)
        let value = try XCTUnwrap(toggle.value)
        toggle.click()
        let changed = NSPredicate { _,_ in
            guard let current = toggle.value else { return false }
            return String(describing:current) != String(describing:value)
        }
        XCTAssertEqual(XCTWaiter.wait(for:[XCTNSPredicateExpectation(predicate:changed,object:nil)],timeout:5),.completed,app.debugDescription)
        window.buttons["settings-change-shortcut"].click()
        XCTAssertTrue(window.sheets.firstMatch.waitForExistence(timeout:5))
        app.typeKey(.escape,modifierFlags:[])
        let shortcutClosed = XCTNSPredicateExpectation(predicate:NSPredicate(format:"exists == false"),object:window.sheets.firstMatch)
        XCTAssertEqual(XCTWaiter.wait(for:[shortcutClosed],timeout:5),.completed,app.debugDescription)
        XCTAssertFalse(window.sheets.firstMatch.exists)
        window.toolbars.buttons["Library"].click()
        XCTAssertTrue(window.buttons["settings-move-library"].waitForExistence(timeout:5))
        window.buttons["settings-move-library"].click()
        let chooser = app.windows["open-panel"]
        XCTAssertTrue(chooser.waitForExistence(timeout:5),app.debugDescription)
        app.typeKey(.escape,modifierFlags:[])
        let chooserClosed = XCTNSPredicateExpectation(predicate:NSPredicate(format:"exists == false"),object:chooser)
        XCTAssertEqual(XCTWaiter.wait(for:[chooserClosed],timeout:5),.completed,app.debugDescription)
        XCTAssertFalse(chooser.exists)
        window.toolbars.buttons["Browser companion"].click()
        XCTAssertTrue(text("Setting up the connection…",in:window))
        XCTAssertFalse(window.buttons["browser-try-again"].exists)
        app.typeKey("w",modifierFlags:.command)
        app.typeKey(",",modifierFlags:.command)
        XCTAssertTrue(window.waitForExistence(timeout:5))
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
        XCTAssertTrue(nativeSaveButton(in:app).waitForExistence(timeout:10),app.debugDescription)
        app.typeKey(.escape,modifierFlags:[])
        let saveButton = nativeSaveButton(in:app)
        let closed = NSPredicate { _,_ in !saveButton.exists }
        XCTAssertEqual(XCTWaiter.wait(for:[XCTNSPredicateExpectation(predicate:closed,object:nil)],timeout:5),.completed,app.debugDescription)
    }
    @MainActor private func nativeSaveButton(in app: XCUIApplication) -> XCUIElement {
        // App-wide queries also match the Touch Bar Save button. The panel
        // itself may be exposed as either a sheet or a window.
        app.descendants(matching:.any).matching(identifier:"save-panel").firstMatch.buttons["OKButton"]
    }
    @MainActor func testExportReceivedAudioThroughAFileOnlySaveGrant() throws {
        // Keep the 52-minute board fixture out of this publication test. The
        // received fixture copies genuine Opus packets through the same saver.
        let app = try launch("received",fixture:"received-only"); defer { app.terminate() }
        XCTAssertTrue(app.buttons["preview-play"].waitForExistence(timeout:20),app.debugDescription)
        app.typeKey("e",modifierFlags:[.command,.shift])
        XCTAssertTrue(app.buttons["export-confirm"].waitForExistence(timeout:10),app.debugDescription)
        app.buttons["export-choose-folder"].click()
        XCTAssertTrue(nativeSaveButton(in:app).waitForExistence(timeout:10),app.debugDescription)
        // The runner can create/inspect its own folder; Cassini receives a
        // file-only Powerbox grant, with no added entitlement or directory grant.
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("CassiniPanelExport-" + UUID().uuidString)
        try FileManager.default.createDirectory(at:destination,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        defer { try? FileManager.default.removeItem(at:destination) }
        app.typeKey("g",modifierFlags:[.command,.shift])
        app.typeText(destination.path); app.typeKey(.return,modifierFlags:[])
        nativeSaveButton(in:app).click()
        XCTAssertTrue(app.buttons["export-confirm"].waitForExistence(timeout:10),app.debugDescription)
        XCTAssertFalse(nativeSaveButton(in:app).exists,"Choose is the sole Save panel")
        app.buttons["export-confirm"].click()
        let output = destination.appendingPathComponent("Onboarding walkthrough.opus")
        let saved = NSPredicate { _,_ in FileManager.default.fileExists(atPath:output.path) }
        let result = XCTWaiter.wait(for:[XCTNSPredicateExpectation(predicate:saved,object:nil)],timeout:20)
        if result != .completed {
            let screenshot = XCTAttachment(screenshot:app.screenshot()); screenshot.name = "save-panel-failure"; screenshot.lifetime = .keepAlways; add(screenshot)
        }
        XCTAssertEqual(result,.completed,app.debugDescription + "\nDestination: " + String(describing:try? FileManager.default.contentsOfDirectory(atPath:destination.path)))
        XCTAssertTrue(app.staticTexts["export-success"].waitForExistence(timeout:10),app.debugDescription)
        XCTAssertTrue(app.buttons["export-show"].exists)
        XCTAssertFalse(nativeSaveButton(in:app).exists)
        capture(app.windows["cassini-library-window"],name:"export-success")
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
        XCTAssertTrue(window.buttons["Change what is recorded"].isEnabled)
        let exact = NSPredicate { _,_ in abs(window.frame.width - 1120) < 0.1 && abs(window.frame.height - 720) < 0.1 }
        XCTAssertEqual(XCTWaiter.wait(for:[XCTNSPredicateExpectation(predicate:exact,object:nil)],timeout:10),.completed)
        XCTAssertFalse(window.textViews["recording-notes"].exists)
        XCTAssertFalse(text("Pinned to the moment you type it.",in:window))
        capture(window,name:"recording")
    }
    @MainActor func testRecordingTitleAndHiddenControls() throws {
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
        app.menuBars.menuBarItems["File"].click()
        XCTAssertFalse(app.menuItems["Rename…"].isEnabled,"Use the Recording page field while live")
        app.typeKey(.escape,modifierFlags:[])
        let openLabel = window.buttons["recording-open-current"].label
        XCTAssertTrue(openLabel.hasPrefix("Open recording, "))
        XCTAssertEqual(window.buttons["recording-stop"].label,"Stop recording")
        for key in ["w","q"] {
            app.typeKey(key,modifierFlags:.command)
            XCTAssertTrue(window.sheets.staticTexts["A recording is running"].waitForExistence(timeout:10),app.debugDescription)
            app.typeKey(.escape,modifierFlags:[])
            let stayed = NSPredicate { _,_ in window.exists && !window.sheets.firstMatch.exists && window.buttons["recording-page-stop"].exists }
            XCTAssertEqual(XCTWaiter.wait(for:[XCTNSPredicateExpectation(predicate:stayed,object:nil)],timeout:5),.completed,app.debugDescription)
        }
        XCTAssertNotEqual(window.buttons["recording-open-current"].label,openLabel,"Elapsed accessible time advances while the recording runs")
        title.click(); app.typeKey("a",modifierFlags:.command); title.typeText("Title from the live page")
        XCTAssertFalse(window.textViews["recording-notes"].exists)
        window.buttons.matching(identifier:"recording-back").firstMatch.click()
        window.buttons["recording-open-current"].click()
        XCTAssertTrue(title.waitForExistence(timeout:10))
        XCTAssertEqual(title.value as? String,"Title from the live page")
        XCTAssertFalse(window.textViews["recording-notes"].exists)
        app.typeKey("q",modifierFlags:.command)
        XCTAssertTrue(window.sheets.buttons["Keep recording"].waitForExistence(timeout:10),app.debugDescription)
        window.sheets.buttons["Keep recording"].click()
        let backgrounded = NSPredicate { _,_ in !window.exists }
        XCTAssertEqual(XCTWaiter.wait(for:[XCTNSPredicateExpectation(predicate:backgrounded,object:nil)],timeout:10),.completed,app.debugDescription)
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
        XCTAssertEqual(actions.compactMap { $0["id"] as? String },["stop","open"])
        XCTAssertEqual(actions.first?["shortcut"] as? String,"⌥⌘R")
        let dump = XCTAttachment(data:data,uniformTypeIdentifier:"public.json")
        dump.name = "recording-menu.json"; dump.lifetime = .keepAlways; add(dump)
        app.buttons["recording-menu-open"].click()
        XCTAssertTrue(title.waitForExistence(timeout:10))
        app.typeKey("h",modifierFlags:.command)
        let finder = XCUIApplication(bundleIdentifier:"com.apple.finder"); finder.activate()
        finder.typeKey("r",modifierFlags:[.option,.command])
        app.activate()
        let saved = NSPredicate { _,_ in window.buttons["preview-play"].exists && window.buttons["preview-play"].isEnabled }
        XCTAssertEqual(XCTWaiter.wait(for:[XCTNSPredicateExpectation(predicate:saved,object:nil)],timeout:15),.completed,app.debugDescription)
        XCTAssertFalse(window.buttons["recording-stop"].exists)
        let notified = NSPredicate { _,_ in
            let value = window.staticTexts["recording-notification-fixture"]
            return (value.value as? String ?? value.label).contains("Recording saved: Title from the live page")
        }
        XCTAssertEqual(XCTWaiter.wait(for:[XCTNSPredicateExpectation(predicate:notified,object:nil)],timeout:5),.completed,"The global shortcut posts feedback after the file is saved")
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
        XCTAssertTrue(window.sheets.staticTexts["Before you record"].waitForExistence(timeout: 20), app.debugDescription)
        XCTAssertTrue(window.sheets.checkBoxes["Don’t show again"].exists)
        XCTAssertTrue(window.sheets.buttons["record-first-start"].exists)
        XCTAssertTrue(text("macOS asks you to allow this.", in: window.sheets.firstMatch))
        XCTAssertFalse(text("macOS asks you to allow this next.",in:window.sheets.firstMatch))
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
        if extra.contains("--fixture-library-recording") || extra.contains("--fixture-library-rename"),
           !app.windows.firstMatch.waitForExistence(timeout: 2) {
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
