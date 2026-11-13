// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import XCTest

final class LibraryBoards: XCTestCase {
    /// D-963: both Stop routes preserve the meeting and expose Resume after the
    /// asynchronous metadata commit. Retained partial words are not a live draft.
    @MainActor func testTranscribingStatusDetailsAndStopKeepsProgress() throws {
        for usePopover in [false,true] {
            let app = try launch("library",fixture:"main",extra:["--fixture-library-rename","-CassiniRenameID",UUID().uuidString])
            defer { app.terminate() }
            let window = app.windows["cassini-library-window"]
            let client = window.outlines.staticTexts.matching(identifier:"meeting-Recording-a0000000-0000-4000-8000-000000000002").firstMatch
            XCTAssertTrue(client.waitForExistence(timeout:20),app.debugDescription)
            client.doubleClick()
            let status = window.staticTexts["transcribing-status"]
            XCTAssertTrue(status.waitForExistence(timeout:10),app.debugDescription)
            XCTAssertEqual(visibleText(status),"Transcribing · about 4 min left")
            XCTAssertEqual(window.buttons["meeting-stop-transcription"].label,"Stop")
            XCTAssertTrue(window.buttons["meeting-play"].isEnabled)
            XCTAssertTrue(window.staticTexts["meeting-title"].isHittable)
            XCTAssertEqual(window.descendants(matching:.any).matching(NSPredicate(format:"identifier BEGINSWITH %@","meeting-turn-")).count,0)
            capture(window,name:"transcribing")
            window.buttons["transcribing-details"].click()
            let stop = app.buttons["transcribing-stop-keep-progress"]
            XCTAssertTrue(stop.waitForExistence(timeout:5),app.debugDescription)
            for label in ["Audio done","Time left","Words so far","Battery at finish","Reading","Preparing","Words","Speakers & matching","Saving"] {
                XCTAssertTrue(app.staticTexts[label].exists,label)
            }
            capture(window,name:"transcribing-details")
            if usePopover { stop.click() }
            else {
                app.typeKey(.escape,modifierFlags:[])
                window.buttons["meeting-stop-transcription"].click()
            }
            let resume = window.buttons["meeting-write-down"]
            XCTAssertTrue(resume.waitForExistence(timeout:10),app.debugDescription)
            XCTAssertEqual(resume.label,"Resume transcription")
            XCTAssertFalse(status.exists)
            XCTAssertTrue(window.buttons["meeting-play"].isEnabled)
            app.terminate()
        }
    }
    @MainActor func testFrenchLibraryAndFirstRunFitAtBoardSize() throws {
        let app=try launch("library",fixture:"main",language:"fr",locale:"fr_FR")
        defer {if app.state != .notRunning {app.terminate()}}
        let window=app.windows["cassini-library-window"]
        let read=window.buttons["preview-read-transcript"]
        XCTAssertTrue(read.waitForExistence(timeout:20),app.debugDescription)
        let title=window.staticTexts["library-toolbar-title"]
        let translated=NSPredicate {_,_ in title.exists && self.visibleText(title)=="Bibliothèque"}
        XCTAssertEqual(XCTWaiter.wait(for:[XCTNSPredicateExpectation(predicate:translated,object:nil)],timeout:10),.completed,app.debugDescription)
        XCTAssertEqual(read.label,"Lire la transcription")
        for button in [read,window.buttons["preview-play"]] {
            XCTAssertTrue(button.isHittable,app.debugDescription)
            XCTAssertTrue(window.frame.contains(button.frame),"French action remains inside the window")
            let width=(button.label as NSString).size(withAttributes:[.font:NSFont.systemFont(ofSize:13)]).width
            XCTAssertGreaterThanOrEqual(button.frame.width+1,width,"French action text has room")
        }
        XCTAssertTrue(window.staticTexts.matching(NSPredicate(format:"value == %@ OR label == %@","Budget review","Budget review")).firstMatch.exists,"Stored meeting names remain verbatim")
        capture(window,name:"library-fr");app.terminate()
        let first=try launch("first-run",fixture:"empty",language:"fr",locale:"fr_FR")
        defer {first.terminate()}
        let empty=first.windows["cassini-library-window"],record=empty.buttons["first-run-record"]
        XCTAssertTrue(record.waitForExistence(timeout:20),first.debugDescription)
        XCTAssertEqual(record.label,"Enregistrer")
        XCTAssertTrue(text("Vos réunions enregistrées apparaîtront ici.",in:empty),first.debugDescription)
        capture(empty,name:"first-run-fr")
        record.click()
        let start=empty.sheets.buttons["record-first-start"]
        XCTAssertTrue(start.waitForExistence(timeout:10),first.debugDescription)
        XCTAssertEqual(start.label,"Commencer l’enregistrement")
        XCTAssertTrue(empty.sheets.firstMatch.frame.contains(start.frame),"Long French primary action fits its sheet")
        let intrinsic=(start.label as NSString).size(withAttributes:[.font:NSFont.systemFont(ofSize:13,weight:.semibold)]).width
        XCTAssertGreaterThanOrEqual(start.frame.width,intrinsic)
        capture(empty,name:"record-first-fr")
    }
    @MainActor func testFrenchLibraryPhrasesWithAmericanRegionalSettings() throws {
        let app=try launch("library",fixture:"main",language:"fr",locale:"en_US")
        defer {if app.state != .notRunning {app.terminate()}}
        let window=app.windows["cassini-library-window"]
        XCTAssertTrue(window.buttons["preview-read-transcript"].waitForExistence(timeout:20),app.debugDescription)
        let header=window.descendants(matching:.any).matching(identifier:"library-day-header-Recording-a0000000-0000-4000-8000-000000000003").firstMatch
        let today=NSPredicate {_,_ in header.exists && self.visibleText(header)=="Aujourd’hui"}
        XCTAssertEqual(XCTWaiter.wait(for:[XCTNSPredicateExpectation(predicate:today,object:nil)],timeout:10),.completed,"French Today header with US region: "+app.debugDescription)
        // The outline's narrow status capsule truncates its AX value along with
        // the drawn text. Inspect the complete phrase in the selected preview.
        let client=window.outlines.staticTexts.matching(identifier:"meeting-Recording-a0000000-0000-4000-8000-000000000002").firstMatch
        XCTAssertTrue(client.waitForExistence(timeout:10),app.debugDescription);client.click()
        // SwiftUI gives every child of the preview-transcribing HStack the
        // stack's identifier, so select the typed StaticText (not the spinner).
        let eta=window.descendants(matching:.any)["preview-transcribing"]
        let etaReady=NSPredicate {_,_ in eta.exists && self.visibleText(eta)=="Transcription · 4 min"}
        XCTAssertEqual(XCTWaiter.wait(for:[XCTNSPredicateExpectation(predicate:etaReady,object:nil)],timeout:10),.completed,"Full French ETA in the selected preview: "+app.debugDescription)
    }
    @MainActor func testFrenchSearchCountWithAmericanRegionalSettings() throws {
        // A separate test must still exercise Search if a Library check fails.
        let search=try launch("search",fixture:"main",language:"fr",locale:"en_US")
        defer {search.terminate()}
        let count=search.windows["cassini-library-window"].staticTexts["search-count"]
        let ready=NSPredicate {_,_ in count.exists && self.visibleText(count)=="4 occurrences dans 3 réunions"}
        XCTAssertEqual(XCTWaiter.wait(for:[XCTNSPredicateExpectation(predicate:ready,object:nil)],timeout:20),.completed,"French Search count with US region: "+search.debugDescription)
    }
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
    /// D52.3a: Recording details opens from the meeting's More menu and closes again.
    @MainActor func testRecordingDetailsFromTheMoreMenu() throws {
        let app = try launch("meeting",fixture:"main"); defer { app.terminate() }
        let window = app.windows["cassini-library-window"]
        let more = window.buttons["meeting-more-actions"]
        XCTAssertTrue(more.waitForExistence(timeout:20),app.debugDescription)
        more.click()
        let item = window.menuItems["recording-details"]
        XCTAssertTrue(item.waitForExistence(timeout:5),app.debugDescription)
        XCTAssertTrue(item.isEnabled); XCTAssertEqual(item.title,"Recording details…")
        XCTAssertTrue(window.menuItems["move-to-trash"].exists)
        item.click()
        let sheet = window.sheets.firstMatch
        XCTAssertTrue(sheet.descendants(matching:.any)["recording-details-sheet"].waitForExistence(timeout:10),app.debugDescription)
        XCTAssertTrue(sheet.staticTexts["recording-details-end"].waitForExistence(timeout:10),"The end line renders after the files are read")
        XCTAssertTrue(sheet.staticTexts["Recording details"].exists)
        capture(window,name:"recording-details")
        sheet.buttons["recording-details-close"].click()
        let closed = NSPredicate { _,_ in !sheet.exists }
        XCTAssertEqual(XCTWaiter.wait(for:[XCTNSPredicateExpectation(predicate:closed,object:nil)],timeout:10),.completed)
    }
    /// codex #105: a call with many sources scrolls inside the sheet; How it ended and
    /// Done stay reachable and Done never leaves the sheet.
    @MainActor func testRecordingDetailsScrollsManySources() throws {
        let app = try launch("library",fixture:"main",extra:["--fixture-library-rename","--fixture-library-many-sources","-CassiniRenameID",UUID().uuidString])
        defer { app.terminate() }
        let window = app.windows["cassini-library-window"]
        let budget = window.staticTexts.matching(NSPredicate(format:"value == %@ OR label == %@","Budget review","Budget review")).firstMatch
        XCTAssertTrue(budget.waitForExistence(timeout:20),app.debugDescription); budget.click()
        let read = window.buttons["preview-read-transcript"]
        XCTAssertTrue(read.waitForExistence(timeout:10),app.debugDescription); read.click()
        let more = window.buttons["meeting-more-actions"]
        XCTAssertTrue(more.waitForExistence(timeout:20),app.debugDescription); more.click()
        let item = window.menuItems["recording-details"]
        XCTAssertTrue(item.waitForExistence(timeout:5),app.debugDescription); item.click()
        let sheet = window.sheets.firstMatch
        let last = sheet.staticTexts["recording-details-source-39"], end = sheet.staticTexts["recording-details-end"]
        XCTAssertTrue(last.waitForExistence(timeout:10) && end.waitForExistence(timeout:10),app.debugDescription)
        let body = sheet.descendants(matching:.any)["recording-details-body"], done = sheet.buttons["recording-details-close"]
        XCTAssertTrue(body.exists,app.debugDescription)
        let screen = NSScreen.screens.first { $0.frame.contains(CGPoint(x:window.frame.midX,y:window.frame.midY)) } ?? NSScreen.main!
        XCTAssertLessThanOrEqual(sheet.frame.height,screen.visibleFrame.height,"The sheet fits the screen")
        XCTAssertTrue(sheet.frame.contains(done.frame) && done.isHittable,"Done stays inside the sheet")
        XCTAssertGreaterThan(end.frame.minY,body.frame.maxY,"Forty sources need scrolling to reach How it ended")
        capture(window,name:"recording-details-many")
        let reached = NSPredicate { _,_ in body.frame.contains(end.frame) && body.frame.contains(last.frame) }
        var delta: CGFloat = -400
        for _ in 0..<20 where !reached.evaluate(with:nil) {
            let before = end.frame.minY
            body.scroll(byDeltaX:0,deltaY:delta)
            if end.frame.minY >= before { delta = -delta } // Scroll direction follows the system setting.
        }
        XCTAssertEqual(XCTWaiter.wait(for:[XCTNSPredicateExpectation(predicate:reached,object:nil)],timeout:10),.completed,"Scrolling reaches the last source and How it ended")
        XCTAssertTrue(sheet.frame.contains(done.frame) && done.isHittable,"Done is still inside the sheet after scrolling")
        done.click()
        let closed = NSPredicate { _,_ in !sheet.exists }
        XCTAssertEqual(XCTWaiter.wait(for:[XCTNSPredicateExpectation(predicate:closed,object:nil)],timeout:10),.completed)
    }
    @MainActor func testMeetingTrashAndSearchKeyboardGuard() throws {
        let app = try launch("meeting",fixture:"main"); defer { app.terminate() }
        let window = app.windows["cassini-library-window"]
        let more = window.buttons["meeting-more-actions"]
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
    @MainActor func testSpeakerNamesClearMergeUndoAndReopen() throws {
        let fixtureID=UUID().uuidString
        let args=["--fixture-library-rename","-CassiniRenameID",fixtureID]
        let app=try launch("library",fixture:"main",extra:args);defer {app.terminate()}
        let window=app.windows["cassini-library-window"]
        let read=window.buttons["preview-read-transcript"]
        app.typeKey(.escape,modifierFlags:[])
        let budget=window.staticTexts.matching(NSPredicate(format:"value == %@ OR label == %@","Budget review","Budget review")).firstMatch
        XCTAssertTrue(budget.waitForExistence(timeout:20),app.debugDescription);budget.click()
        let readable=NSPredicate {_,_ in read.exists && read.isEnabled}
        XCTAssertEqual(XCTWaiter.wait(for:[XCTNSPredicateExpectation(predicate:readable,object:nil)],timeout:10),.completed,app.debugDescription)
        read.click()
        let nameSpeakers = window.buttons["name-the-speakers"]
        XCTAssertTrue(nameSpeakers.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(nameSpeakers.isEnabled)
        nameSpeakers.click()
        let nameField = app.textFields["speaker-name-field"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 10), app.debugDescription)
        app.typeKey(.escape, modifierFlags: [])
        let dismissed = NSPredicate { _,_ in !nameField.exists }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: dismissed, object: nil)], timeout: 10), .completed)
        let marta=window.buttons["speaker-name-marta"]
        XCTAssertTrue(marta.waitForExistence(timeout:10),app.debugDescription);marta.click()
        let field=app.textFields["speaker-name-field"],save=app.buttons["speaker-save-name"]
        XCTAssertTrue(field.waitForExistence(timeout:10),app.debugDescription)
        field.click();app.typeKey("a",modifierFlags:.command);field.typeText(" Ada ");save.click()
        let named=NSPredicate {_,_ in !field.exists && marta.exists && marta.label.contains("Ada")}
        XCTAssertEqual(XCTWaiter.wait(for:[XCTNSPredicateExpectation(predicate:named,object:nil)],timeout:10),.completed,app.debugDescription)
        XCTAssertTrue(window.buttons["speaker-listen-marta"].exists,"The independent row Play target remains available")
        let editableCaption=window.descendants(matching:.any).matching(identifier:"speaker-caption-marta").firstMatch
        XCTAssertTrue(editableCaption.exists)
        XCTAssertGreaterThanOrEqual(editableCaption.frame.width,185,"Play stays on the name/share line so editable captions keep full row width")
        marta.click();XCTAssertTrue(field.waitForExistence(timeout:10))
        field.click();app.typeKey("a",modifierFlags:.command);field.typeText(String(repeating:"x",count:65))
        XCTAssertFalse(save.isEnabled,"Overlong names cannot be saved")
        app.typeKey(.escape,modifierFlags:[])
        XCTAssertEqual(XCTWaiter.wait(for:[XCTNSPredicateExpectation(predicate:NSPredicate {_,_ in !field.exists},object:nil)],timeout:10),.completed)
        XCTAssertTrue(marta.label.contains("Ada"),"Cancel leaves the saved name intact")
        marta.click();XCTAssertTrue(field.waitForExistence(timeout:10))
        field.click();app.typeKey("a",modifierFlags:.command);app.typeKey(.delete,modifierFlags:[]);save.click()
        let cleared=NSPredicate {_,_ in !field.exists && marta.exists && !marta.label.contains("Ada")}
        XCTAssertEqual(XCTWaiter.wait(for:[XCTNSPredicateExpectation(predicate:cleared,object:nil)],timeout:10),.completed,app.debugDescription)
        let dario=window.buttons["speaker-name-dario"]
        XCTAssertTrue(dario.exists);dario.click();XCTAssertTrue(field.waitForExistence(timeout:10))
        app.descendants(matching:.any).matching(identifier:"speaker-merge-menu").firstMatch.click();app.menuItems["Speaker 3"].click()
        let merged=NSPredicate {_,_ in !field.exists && !dario.exists && window.buttons["speaker-name-guest"].exists}
        XCTAssertEqual(XCTWaiter.wait(for:[XCTNSPredicateExpectation(predicate:merged,object:nil)],timeout:10),.completed,app.debugDescription)
        window.buttons["meeting-more-actions"].click();app.menuItems["Undo merge"].click()
        XCTAssertTrue(dario.waitForExistence(timeout:10),app.debugDescription)
        app.terminate()
        let reopened=try launch("library",fixture:"main",extra:args);defer {reopened.terminate()}
        let again=reopened.windows["cassini-library-window"]
        reopened.typeKey(.escape,modifierFlags:[])
        let budgetAgain=again.staticTexts.matching(NSPredicate(format:"value == %@ OR label == %@","Budget review","Budget review")).firstMatch
        XCTAssertTrue(budgetAgain.waitForExistence(timeout:20));budgetAgain.click()
        let readAgain=again.buttons["preview-read-transcript"]
        XCTAssertEqual(XCTWaiter.wait(for:[XCTNSPredicateExpectation(predicate:NSPredicate {_,_ in readAgain.exists && readAgain.isEnabled},object:nil)],timeout:10),.completed)
        readAgain.click()
        XCTAssertTrue(again.buttons["speaker-name-dario"].waitForExistence(timeout:10))
        XCTAssertFalse(again.buttons["speaker-name-marta"].label.contains("Ada"),"The clear and Undo survive reopening")
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
        let blank = NSPredicate { _,_ in (title.value as? String ?? title.label) == "Budget review" && !field.exists }
        XCTAssertEqual(XCTWaiter.wait(for:[XCTNSPredicateExpectation(predicate:blank,object:nil)],timeout:10),.completed,app.debugDescription)
        XCTAssertTrue(window.staticTexts["meeting-subtitle"].exists,"Restoring the automatic name retains the date/duration subtitle")
        title.click(); XCTAssertTrue(field.waitForExistence(timeout:10))
        XCTAssertFalse(app.buttons["rename-confirm"].isEnabled)
        field.typeText("Cancelled name"); app.typeKey(.escape,modifierFlags:[])
        let cancelled = NSPredicate { _,_ in !field.exists && (title.value as? String ?? title.label) == "Budget review" }
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
        XCTAssertTrue(text("macOS asks you to allow this.",in:window.sheets.firstMatch))
        XCTAssertFalse(text("macOS asks you to allow this next.",in:window.sheets.firstMatch))
        app.typeKey(.escape,modifierFlags:[])
        XCTAssertTrue(window.buttons["first-run-record"].exists)
        XCTAssertFalse(app.buttons["recording-stop"].exists,"Reading consent captions must never start a capture")
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
            XCTAssertTrue(waitForPresent(window.buttons["preview-play"],timeout:20),app.debugDescription)
            XCTAssertFalse(window.descendants(matching:.any)["capture-failure-banner"].exists)
            if kind == "lost" {
                XCTAssertTrue(waitForPresent(window.buttons["browser-try-again"],timeout:10),app.debugDescription)
                XCTAssertTrue(window.staticTexts["library-browser-status"].exists)
            } else { XCTAssertFalse(window.staticTexts["library-browser-status"].exists) }
            app.typeKey(",",modifierFlags:.command)
            let settings = app.windows["cassini-settings-window"]
            XCTAssertTrue(waitForPresent(settings,timeout:10))
            settings.toolbars.buttons["Browser companion"].click()
            if kind == "absent" {
                let add = settings.buttons["browser-add"]
                XCTAssertTrue(waitForPresent(add,timeout:10),app.debugDescription); XCTAssertFalse(add.isEnabled)
                XCTAssertTrue(text("Browser meetings need Chrome, Edge, Brave or Chromium.",in:settings))
                XCTAssertFalse(settings.buttons["browser-try-again"].exists)
                app.typeKey("w",modifierFlags:.command)
                let budget = window.staticTexts.matching(NSPredicate(format:"value == %@ OR label == %@","Budget review","Budget review")).firstMatch
                budget.click()
                XCTAssertTrue(window.buttons["preview-read-transcript"].isEnabled)
                window.buttons["preview-read-transcript"].click()
                XCTAssertTrue(waitForPresent(window.buttons["Set up"],timeout:15),app.debugDescription)
                window.buttons["Set up"].click()
                XCTAssertTrue(waitForPresent(window.sheets.buttons["companion-add"],timeout:10),app.debugDescription)
                XCTAssertFalse(window.sheets.buttons["companion-add"].isEnabled)
                XCTAssertFalse(window.sheets.buttons["companion-connect"].exists)
                XCTAssertFalse(text("Couldn’t connect.",in:window.sheets.firstMatch))
                window.sheets.buttons["Not now"].click()
            } else if kind == "first" {
                XCTAssertTrue(waitForPresent(settings.buttons["browser-add"],timeout:10)); XCTAssertTrue(settings.buttons["browser-add"].isEnabled)
                XCTAssertFalse(settings.buttons["browser-try-again"].exists)
            } else { XCTAssertTrue(waitForPresent(settings.buttons["browser-try-again"],timeout:10)) }
            app.terminate()
        }
    }
    @MainActor func testListeningBarSteppingAndEscapeLeaveThePositionInPlace() throws {
        let app = try launch("meeting",fixture:"main",extra:["-CassiniListeningPreview","playing","-CassiniListeningSpeaker","marta"])
        defer { app.terminate() }
        let window = app.windows["cassini-library-window"]
        let bar = window.descendants(matching:.any)["listening-bar"]
        XCTAssertTrue(bar.waitForExistence(timeout:20),app.debugDescription)
        XCTAssertFalse(window.buttons["listen.previousTurn"].isEnabled)
        XCTAssertTrue(window.buttons["listen.nextTurn"].isEnabled)
        XCTAssertTrue(window.buttons["listen.nextTurn"].isHittable,"The listening bar must expose a real mouse target")
        window.buttons["listen.nextTurn"].click()
        let last = NSPredicate { _,_ in !window.buttons["listen.nextTurn"].isEnabled && self.text("Turn 2 of 2 · 00:03:20",in:window) }
        XCTAssertEqual(XCTWaiter.wait(for:[XCTNSPredicateExpectation(predicate:last,object:nil)],timeout:5),.completed)
        app.typeKey(.downArrow,modifierFlags:[.option,.shift,.command])
        XCTAssertEqual(XCTWaiter.wait(for:[XCTNSPredicateExpectation(predicate:NSPredicate { _,_ in self.text("Turn 1 of 2 · 00:02:55",in:window) },object:nil)],timeout:5),.completed)
        let name=bar.buttons["listen-name"]
        let merge=bar.descendants(matching:.any).matching(identifier:"listen-merge").firstMatch
        XCTAssertTrue(name.exists && merge.exists)
        XCTAssertFalse(name.isEnabled,"The screenshot's read-only fixture cannot be renamed")
        XCTAssertFalse(merge.isEnabled,"The screenshot's read-only fixture cannot be merged")
        window.buttons["meeting-export"].click()
        XCTAssertTrue(window.sheets.firstMatch.waitForExistence(timeout:10))
        app.typeKey(.escape,modifierFlags:[])
        XCTAssertEqual(XCTWaiter.wait(for:[XCTNSPredicateExpectation(predicate:NSPredicate(format:"exists == false"),object:window.sheets.firstMatch)],timeout:5),.completed)
        XCTAssertTrue(bar.exists,"Escape belongs to the export sheet before listening")
        // These must recover after AppKit finishes dismissing the sheet.
        for (key, modifiers, label) in [
            (XCUIKeyboardKey.downArrow, XCUIElement.KeyModifierFlags([.option,.command]), "Turn 2 of 2 · 00:03:31"),
            (.upArrow, [.option,.command], "Turn 1 of 2 · 00:02:55"),
            (.downArrow, [.option,.shift,.command], "Turn 1 of 1 · 00:03:08"),
            (.upArrow, [.option,.shift,.command], "Turn 1 of 2 · 00:02:55")
        ] {
            app.typeKey(key,modifierFlags:modifiers)
            XCTAssertEqual(XCTWaiter.wait(for:[XCTNSPredicateExpectation(predicate:NSPredicate { _,_ in self.text(label,in:window) },object:nil)],timeout:5),.completed)
        }
        let before = window.sliders["meeting-seek"].value as? String
        app.typeKey(.escape,modifierFlags:[])
        XCTAssertEqual(XCTWaiter.wait(for:[XCTNSPredicateExpectation(predicate:NSPredicate(format:"exists == false"),object:bar)],timeout:5),.completed)
        XCTAssertEqual(window.sliders["meeting-seek"].value as? String,before)
    }
    @MainActor func testListeningBarOffersPlayAgainAfterItsLastTurn() throws {
        let app = try launch("meeting",fixture:"main",extra:["-CassiniListeningPreview","finished","-CassiniListeningSpeaker","guest"])
        defer { app.terminate() }
        let window = app.windows["cassini-library-window"], again = window.buttons["listen-again"]
        XCTAssertTrue(again.waitForExistence(timeout:20),app.debugDescription)
        XCTAssertTrue(text("Turn 1 of 1 · 00:03:08",in:window))
        XCTAssertFalse(window.buttons["listen.nextTurn"].isEnabled)
        capture(window,name:"listening-bar-finished")
        XCTAssertTrue(again.isHittable,"Play again must expose a real mouse target")
        again.click()
        XCTAssertEqual(XCTWaiter.wait(for:[XCTNSPredicateExpectation(predicate:NSPredicate(format:"exists == false"),object:again)],timeout:5),.completed)
        XCTAssertTrue(window.descendants(matching:.any)["listening-bar"].exists)
    }
    @MainActor func testListeningScrubberSnapsWithinSixPointsAndStopClearsSnapping() throws {
        let app = try launch("meeting",fixture:"main",extra:["-CassiniListeningPreview","playing","-CassiniListeningSpeaker","guest"])
        defer { app.terminate() }
        let window = app.windows["cassini-library-window"], slider = window.sliders["meeting-seek"]
        XCTAssertTrue(slider.waitForExistence(timeout:20),app.debugDescription)
        let thumb = slider.valueIndicators.firstMatch
        XCTAssertTrue(thumb.waitForExistence(timeout:5),slider.debugDescription)
        let frame = slider.frame
        let point = slider.coordinate(withNormalizedOffset:.zero).withOffset(
            CGVector(dx:thumb.frame.midX-frame.minX+5,dy:thumb.frame.midY-frame.minY))
        let far = slider.coordinate(withNormalizedOffset:CGVector(dx:0.8,dy:0.5))
        far.click()
        let moved = NSPredicate { _,_ in slider.value as? String != "00:03:08" }
        XCTAssertEqual(XCTWaiter.wait(for:[XCTNSPredicateExpectation(predicate:moved,object:nil)],timeout:5),.completed)
        let farValue = slider.value as? String
        point.click()
        let snapped = NSPredicate { _,_ in slider.value as? String == "00:03:08" }
        XCTAssertEqual(XCTWaiter.wait(for:[XCTNSPredicateExpectation(predicate:snapped,object:nil)],timeout:5),.completed,"A five-point near miss selects the exact turn")
        XCTAssertTrue(window.descendants(matching:.any)["listening-bar"].exists)
        window.buttons["listen-stop"].click()
        let stopped = NSPredicate { _,_ in !window.descendants(matching:.any)["listening-bar"].exists }
        XCTAssertEqual(XCTWaiter.wait(for:[XCTNSPredicateExpectation(predicate:stopped,object:nil)],timeout:5),.completed)
        XCTAssertEqual(slider.value as? String,"00:03:08","The snap survives completion of the Stop event")
        far.click()
        XCTAssertEqual(XCTWaiter.wait(for:[XCTNSPredicateExpectation(predicate:NSPredicate { _,_ in slider.value as? String == farValue },object:nil)],timeout:5),.completed)
        point.click()
        let free = NSPredicate { _,_ in slider.value as? String != "00:03:08" && slider.value as? String != farValue }
        XCTAssertEqual(XCTWaiter.wait(for:[XCTNSPredicateExpectation(predicate:free,object:nil)],timeout:5),.completed,"Stopping listening clears pointer snapping")
    }
    @MainActor func testScrubberDragClampsAtBothEndsWithAnOffCenterThumbGrab() throws {
        let app = try launch("meeting",fixture:"main",extra:["-CassiniListeningPreview","finished","-CassiniListeningSpeaker","guest"])
        defer { app.terminate() }
        let window = app.windows["cassini-library-window"], slider = window.sliders["meeting-seek"]
        XCTAssertTrue(slider.waitForExistence(timeout:20),app.debugDescription)
        let thumb = slider.valueIndicators.firstMatch
        XCTAssertTrue(thumb.waitForExistence(timeout:5),slider.debugDescription)
        let frame = slider.frame
        let anchor = slider.coordinate(withNormalizedOffset:.zero)
        func grab(_ offset:CGFloat) -> XCUICoordinate {
            anchor.withOffset(CGVector(dx:thumb.frame.midX-frame.minX+offset,dy:thumb.frame.midY-frame.minY))
        }
        let before = try XCTUnwrap(slider.value as? String)
        XCTAssertNotEqual(before,"00:03:08","The finished readout must differ from the turn start so a wrong seek is visible")
        XCTAssertTrue(window.buttons["listen-again"].exists,"Finished Listening is the regression precondition")
        grab(5).click()
        XCTAssertEqual(slider.value as? String,before,"An off-center stationary thumb grab must not snap to 00:03:08")
        XCTAssertTrue(window.buttons["listen-again"].exists,"A stationary grab must preserve finished Listening")
        window.buttons["listen-stop"].click()
        let stopped = NSPredicate { _,_ in !window.descendants(matching:.any)["listening-bar"].exists }
        XCTAssertEqual(XCTWaiter.wait(for:[XCTNSPredicateExpectation(predicate:stopped,object:nil)],timeout:5),.completed)
        grab(5).press(forDuration:0,
            thenDragTo:anchor.withOffset(CGVector(dx:frame.width+40,dy:frame.height/2)))
        let atEnd = NSPredicate { _,_ in slider.value as? String == "00:47:05" }
        XCTAssertEqual(XCTWaiter.wait(for:[XCTNSPredicateExpectation(predicate:atEnd,object:nil)],timeout:5),.completed)
        grab(-5).press(forDuration:0,
            thenDragTo:anchor.withOffset(CGVector(dx:-40,dy:frame.height/2)))
        let atStart = NSPredicate { _,_ in slider.value as? String == "00:00:00" }
        XCTAssertEqual(XCTWaiter.wait(for:[XCTNSPredicateExpectation(predicate:atStart,object:nil)],timeout:5),.completed)
    }

    @MainActor func testTranscriptTimePlaysAndSpeakerNameStartsListening() throws {
        let app = try launch("meeting",fixture:"main")
        defer { app.terminate() }
        let window = app.windows["cassini-library-window"]
        let play = window.buttons["turn-play-2"], listen = window.buttons["turn-listen-2"]
        XCTAssertTrue(play.waitForExistence(timeout:20),app.debugDescription)
        XCTAssertTrue(listen.isEnabled && play.isEnabled,"Read-only transcript actions stay available")
        XCTAssertEqual(play.label,"Play from here, 00:03:08")
        XCTAssertTrue(listen.label.hasPrefix("Listen to "))
        play.click()
        let played = NSPredicate { _,_ in window.sliders["meeting-seek"].value as? String == "00:03:08" }
        XCTAssertEqual(XCTWaiter.wait(for:[XCTNSPredicateExpectation(predicate:played,object:nil)],timeout:5),.completed)
        XCTAssertFalse(window.descendants(matching:.any)["listening-bar"].exists)
        listen.click()
        XCTAssertTrue(window.descendants(matching:.any)["listening-bar"].waitForExistence(timeout:5))
        XCTAssertTrue(text("Turn 1 of 1 · 00:03:08",in:window))
        capture(window,name:"listening-transcript-highlight")
        window.buttons["listen-stop"].click()
        XCTAssertEqual(window.sliders["meeting-seek"].value as? String,"00:03:08")
    }
    @MainActor func testPlaybackMenuPlaysFocusedTranscriptAndYieldsToSheetsAndSearch() throws {
        let app = try launch("meeting",fixture:"main")
        defer { app.terminate() }
        let window = app.windows["cassini-library-window"]
        let row = window.descendants(matching:.any).matching(identifier:"meeting-turn-0").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout:20),app.debugDescription)
        window.buttons["meeting-play"].click() // pause the frozen fixture first
        row.coordinate(withNormalizedOffset:CGVector(dx:0.55,dy:0.2)).click()
        app.menuBars.menuBarItems["Playback"].click()
        XCTAssertTrue(app.menuItems["Play this turn"].isEnabled,app.debugDescription)
        XCTAssertFalse(app.menuItems["Next turn"].isEnabled,"Stepping remains listening-only")
        app.menuItems["Play this turn"].click()
        let played = NSPredicate { _,_ in window.buttons["meeting-play"].label == "Pause" && window.sliders["meeting-seek"].value as? String == "00:02:41" }
        XCTAssertEqual(XCTWaiter.wait(for:[XCTNSPredicateExpectation(predicate:played,object:nil)],timeout:5),.completed)
        // The same native text focus also handles the visible ⇧Return shortcut.
        window.buttons["meeting-play"].click()
        row.coordinate(withNormalizedOffset:CGVector(dx:0.55,dy:0.2)).click()
        app.typeKey(.return,modifierFlags:.shift)
        XCTAssertEqual(XCTWaiter.wait(for:[XCTNSPredicateExpectation(predicate:played,object:nil)],timeout:5),.completed)
        window.buttons["meeting-export"].click()
        XCTAssertTrue(window.sheets.firstMatch.waitForExistence(timeout:10))
        app.menuBars.menuBarItems["Playback"].click()
        for title in ["Play this turn","Previous turn","Next turn","Previous speaker","Next speaker"] {
            XCTAssertFalse(app.menuItems[title].isEnabled,"A sheet owns keyboard input: " + title)
        }
        app.typeKey(.escape,modifierFlags:[]) // menu
        app.typeKey(.escape,modifierFlags:[]) // export sheet
        XCTAssertEqual(XCTWaiter.wait(for:[XCTNSPredicateExpectation(predicate:NSPredicate(format:"exists == false"),object:window.sheets.firstMatch)],timeout:5),.completed)
        app.typeKey("f",modifierFlags:.command)
        XCTAssertTrue(window.searchFields.firstMatch.waitForExistence(timeout:5))
        app.menuBars.menuBarItems["Playback"].click()
        for title in ["Play this turn","Previous turn","Next turn","Previous speaker","Next speaker"] {
            XCTAssertFalse(app.menuItems[title].isEnabled,"Search owns keyboard input: " + title)
        }
        app.typeKey(.escape,modifierFlags:[]) // menu
        app.typeKey(.escape,modifierFlags:[]) // search
        // Opening search already leaves the meeting (LibrarySearchModel.open).
        // Closing search returns to the Library preview, not the old detail page.
        XCTAssertTrue(window.buttons["preview-read-transcript"].waitForExistence(timeout:5))
        XCTAssertFalse(window.buttons["meeting-back"].exists,"Search already left the meeting page")
        app.menuBars.menuBarItems["Playback"].click()
        XCTAssertFalse(app.menuItems["Play this turn"].isEnabled,"Leaving the page clears its focused transcript action")
    }
    @MainActor func testCompanionHealthUsesExplicitTabAdviceAndFileCheckedSetup() throws {
        for kind in ["health-ready","health-idle","health-reload","health-reload-no-action","health-reload-no-capability","health-reload-active","health-files","health-outdated","health-legacy"] {
            let app = try launch("library",fixture:"main",extra:["--fixture-library-rename","-CassiniRenameID",UUID().uuidString,"-CassiniBrowserCase",kind])
            let window = app.windows["cassini-library-window"]
            XCTAssertTrue(waitForPresent(window.buttons["preview-play"],timeout:20),app.debugDescription)
            app.typeKey(",",modifierFlags:.command)
            let settings = app.windows["cassini-settings-window"]
            XCTAssertTrue(waitForPresent(settings,timeout:10))
            settings.toolbars.buttons["Browser companion"].click()
            let message = settings.staticTexts["companion-reload-message"]
            if kind == "health-reload" {
                XCTAssertTrue(waitForPresent(message,timeout:10),app.debugDescription)
                XCTAssertEqual(visibleText(message),"Reload the meeting tab so Cassini can record it.")
                XCTAssertTrue(settings.buttons.matching(NSPredicate(format:"identifier BEGINSWITH %@","companion-reload-tab-")).firstMatch.isEnabled)
            } else { XCTAssertFalse(message.exists,"An idle or healthy browser must not get reload advice") }
            if kind != "health-reload" {
                XCTAssertFalse(settings.buttons.matching(NSPredicate(format:"identifier BEGINSWITH %@","companion-reload-tab-")).firstMatch.exists,"Ineligible reload guidance has no dead action")
            }
            let setupAgain = settings.buttons["companion-setup-again"]
            XCTAssertEqual(settings.staticTexts["companion-files-missing"].exists,kind == "health-files","Only explicit filesOk=false shows the missing-files line")
            if ["health-files","health-outdated"].contains(kind) {
                XCTAssertTrue(waitForPresent(setupAgain,timeout:10)); setupAgain.click()
                let done = settings.sheets.buttons["companion-local-done"]
                XCTAssertTrue(waitForPresent(done,timeout:10),app.debugDescription)
                XCTAssertFalse(settings.sheets.buttons["companion-setup-again"].exists,"The open local guide already offers Prepare folder")
                XCTAssertEqual(done.isEnabled,kind == "health-outdated","Done requires connection and no explicit file failure; versions do not gate capabilities")
                if kind == "health-files" { XCTAssertTrue(settings.sheets.staticTexts["companion-files-missing"].exists) }
                app.typeKey(.escape,modifierFlags:[])
                XCTAssertTrue(waitForPresent(setupAgain,timeout:5),"Repair remains available after closing the local guide")
            } else { XCTAssertFalse(setupAgain.exists) }
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
        for id in ["marta","giulia","guest"] {
            let play = window.buttons["speaker-listen-" + id]
            XCTAssertTrue(play.waitForExistence(timeout:5),app.debugDescription)
            XCTAssertTrue(play.isEnabled && play.isHittable,"Read-only speaker rows expose their own Play button")
            XCTAssertTrue(play.label.hasPrefix("Play this speaker’s turns:") && play.label.contains("at 00:"),play.label)
            XCTAssertTrue(window.frame.contains(play.frame),"The action stays within the 260-point pane")
        }
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
        XCTAssertTrue(text("444 MB download",in:window))
        XCTAssertFalse(text("To check for updates. No meeting data is sent.",in:window))
        capture(window,name:"settings-transcription")
    }
    @MainActor func testParakeetRecommendationCapabilityAndPersistedDismissal() throws {
        let low = try launch("settings-transcription",fixture:"main",extra:["-CassiniSettingsID",UUID().uuidString,
            "-CassiniSpeechMemoryBytes",String((UInt64(8) << 30)-1)])
        let lowWindow = low.windows["cassini-settings-window"]
        XCTAssertTrue(lowWindow.descendants(matching:.any).matching(identifier:"settings-speech-models-ready").firstMatch.waitForExistence(timeout:20),low.debugDescription)
        XCTAssertFalse(lowWindow.descendants(matching:.any).matching(identifier:"settings-parakeet-suggestion").firstMatch.exists)
        low.terminate()
        for (language,locale) in [("en-GB","en_GB"),("fr-FR","fr_FR"),("pt-PT","pt_PT")] {
            let identity = UUID().uuidString
            let arguments = ["-CassiniSettingsID",identity,"-CassiniSpeechMemoryBytes",String(UInt64(8) << 30)]
            let app = try launch("settings-transcription",fixture:"main",extra:arguments,language:language,locale:locale)
            let window = app.windows["cassini-settings-window"]
            XCTAssertTrue(window.descendants(matching:.any).matching(identifier:"settings-speech-models-ready").firstMatch.waitForExistence(timeout:20),app.debugDescription)
            let card = window.descendants(matching:.any).matching(identifier:"settings-parakeet-suggestion").firstMatch
            XCTAssertTrue(card.waitForExistence(timeout:5),app.debugDescription)
            XCTAssertTrue(card.descendants(matching:.staticText).allElementsBoundByIndex.contains { element in
                String(describing:element.value ?? element.label).contains("444")
            },card.debugDescription)
            XCTAssertTrue(window.buttons["settings-parakeet-suggestion-download"].isHittable)
            capture(window,name:"settings-parakeet-recommendation-"+language)
            // SwiftUI's link button style exposes this action as an AX link.
            // Match its identifier independently of the platform element role.
            let notNow = window.descendants(matching:.any).matching(identifier:"settings-parakeet-not-now").firstMatch
            XCTAssertTrue(notNow.waitForExistence(timeout:5),window.debugDescription)
            XCTAssertTrue(notNow.isHittable)
            notNow.click()
            let hidden = NSPredicate { _,_ in !card.exists }
            XCTAssertEqual(XCTWaiter.wait(for:[XCTNSPredicateExpectation(predicate:hidden,object:nil)],timeout:5),.completed)
            app.terminate()
            let relaunched = try launch("settings-transcription",fixture:"main",extra:arguments,language:language,locale:locale)
            let restored = relaunched.windows["cassini-settings-window"]
            XCTAssertTrue(restored.descendants(matching:.any).matching(identifier:"settings-speech-models-ready").firstMatch.waitForExistence(timeout:20),relaunched.debugDescription)
            XCTAssertFalse(restored.descendants(matching:.any).matching(identifier:"settings-parakeet-suggestion").firstMatch.exists)
            relaunched.terminate()
        }
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
        window.toolbars.buttons["Updates"].click()
        let updatesToggle = window.descendants(matching:.any).matching(identifier:"settings-automatic-updates").firstMatch
        XCTAssertTrue(updatesToggle.waitForExistence(timeout:5),window.debugDescription)
        XCTAssertTrue(window.buttons["settings-check-updates"].exists,window.debugDescription)
        window.toolbars.buttons["Library"].click()
        XCTAssertTrue(window.buttons["settings-move-library"].waitForExistence(timeout:5))
        window.buttons["settings-move-library"].click()
        let chooser = app.windows["open-panel"]
        XCTAssertTrue(chooser.waitForExistence(timeout:5),app.debugDescription)
        app.typeKey(.escape,modifierFlags:[])
        let chooserClosed = XCTNSPredicateExpectation(predicate:NSPredicate(format:"exists == false"),object:chooser)
        XCTAssertEqual(XCTWaiter.wait(for:[chooserClosed],timeout:5),.completed,app.debugDescription)
        XCTAssertFalse(chooser.exists)
        let exportAll = window.buttons["settings-export-all-zip"]
        XCTAssertTrue(exportAll.waitForExistence(timeout:5),window.debugDescription)
        XCTAssertTrue(exportAll.isEnabled,window.debugDescription)
        exportAll.click()
        let savePresented = NSPredicate { _,_ in window.sheets.firstMatch.exists || app.windows["save-panel"].exists }
        XCTAssertEqual(XCTWaiter.wait(for:[XCTNSPredicateExpectation(predicate:savePresented,object:nil)],timeout:5),.completed,app.debugDescription)
        app.typeKey(.escape,modifierFlags:[])
        let saveClosed = NSPredicate { _,_ in !window.sheets.firstMatch.exists && !app.windows["save-panel"].exists }
        XCTAssertEqual(XCTWaiter.wait(for:[XCTNSPredicateExpectation(predicate:saveClosed,object:nil)],timeout:5),.completed,app.debugDescription)
        window.toolbars.buttons["Browser companion"].click()
        XCTAssertTrue(text("Setting up the connection…",in:window))
        XCTAssertFalse(window.buttons["browser-try-again"].exists)
        app.typeKey("w",modifierFlags:.command)
        app.typeKey(",",modifierFlags:.command)
        XCTAssertTrue(window.waitForExistence(timeout:5))
    }
    @MainActor func testLibrary() throws { try board("library", fixture: "main") }
    @MainActor func testFirstRun() throws { try board("first-run", fixture: "empty") }
    @MainActor func testSearchClickOpensSidebarBeforeTyping() throws {
        let app = try launch("library",fixture:"main"); defer { app.terminate() }
        let window = app.windows["cassini-library-window"]
        let field = window.searchFields["library-search-field"]
        XCTAssertTrue(field.waitForExistence(timeout:20),app.debugDescription)
        field.click()
        // Wait for the sidebar before sending the first keyboard event.
        let count = window.staticTexts["search-count"]
        XCTAssertTrue(count.waitForExistence(timeout:5),app.debugDescription)
        app.typeText("budget")
        let value = NSPredicate { _,_ in field.value as? String == "budget" }
        XCTAssertEqual(XCTWaiter.wait(for:[XCTNSPredicateExpectation(predicate:value,object:nil)],timeout:5),.completed,app.debugDescription)
        XCTAssertTrue(count.waitForExistence(timeout:5))
        app.typeKey(.escape,modifierFlags:[])
        XCTAssertTrue(window.buttons["preview-read-transcript"].waitForExistence(timeout:5))
        field.click(); app.typeText("Daniel")
        XCTAssertEqual(field.value as? String,"Daniel",app.debugDescription)
        app.typeKey(.escape,modifierFlags:[])
        app.typeKey("f",modifierFlags:.command); app.typeText("budget")
        XCTAssertEqual(field.value as? String,"budget","Cmd-F also retains the whole query")
    }
    @MainActor func testMeetingTranscriptSelectionAndCopy() throws {
        let app = try launch("meeting",fixture:"main"); defer { app.terminate() }
        let window = app.windows["cassini-library-window"]
        let turn = window.descendants(matching:.any).matching(NSPredicate(format:"identifier BEGINSWITH %@","meeting-turn-")).firstMatch
        XCTAssertTrue(turn.waitForExistence(timeout:20),app.debugDescription)
        // The text is to the right of the speaker column. Select with the
        // pointer, then use the real Edit actions through the responder chain.
        let start = turn.coordinate(withNormalizedOffset:CGVector(dx:0.35,dy:0.35))
        let end = turn.coordinate(withNormalizedOffset:CGVector(dx:0.80,dy:0.35))
        let initialPosition = visibleText(window.staticTexts["meeting-elapsed"])
        XCTAssertEqual(initialPosition,"00:03:12")
        start.press(forDuration:0.1,thenDragTo:end)
        XCTAssertEqual(visibleText(window.staticTexts["meeting-elapsed"]),initialPosition,"Dragging selects without seeking")
        app.menuBars.menuBarItems["Edit"].click()
        XCTAssertTrue(app.menuItems["Copy"].isEnabled,app.debugDescription)
        XCTAssertTrue(app.menuItems["Select All"].isEnabled,app.debugDescription)
        app.menuItems["Select All"].click()
        NSPasteboard.general.clearContents()
        app.typeKey("c",modifierFlags:.command)
        let copied = NSPredicate { _,_ in !(NSPasteboard.general.string(forType:.string) ?? "").isEmpty }
        XCTAssertEqual(XCTWaiter.wait(for:[XCTNSPredicateExpectation(predicate:copied,object:nil)],timeout:5),.completed)
        let text = NSPasteboard.general.string(forType:.string) ?? ""
        // Native Select All selects the focused text view (this first turn),
        // rather than unrelated turns elsewhere in the transcript.
        XCTAssertEqual(text,"Thanks for making the time. We wanted to go through the delivery dates before the end of the month.")
        XCTAssertFalse(text.contains("cassini-seek:"),"Copy carries readable words, not playback URLs")
        XCTAssertTrue(window.buttons["meeting-back"].exists,"Copy keeps the meeting open")
        start.click()
        // This exact sentence in the shared main fixture starts at161000 ms.
        let sought = NSPredicate { _,_ in self.visibleText(window.staticTexts["meeting-elapsed"]) == "00:02:41" }
        XCTAssertEqual(XCTWaiter.wait(for:[XCTNSPredicateExpectation(predicate:sought,object:nil)],timeout:5),.completed,"Selecting text must preserve click-to-seek: " + app.debugDescription)
    }
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
        XCTAssertTrue(waitForPresent(window.buttons["first-run-record"],timeout:20))
        window.buttons["first-run-record"].click()
        XCTAssertTrue(waitForPresent(window.sheets.buttons["record-first-start"],timeout:10))
        window.sheets.checkBoxes["Don’t show again"].click()
        window.sheets.buttons["record-first-start"].click()
        let title = window.textFields["recording-title"]
        XCTAssertTrue(waitForPresent(title,timeout:10),app.debugDescription)
        app.menuBars.menuBarItems["File"].click()
        XCTAssertFalse(app.menuItems["Rename…"].isEnabled,"Use the Recording page field while live")
        app.typeKey(.escape,modifierFlags:[])
        let openRecording = window.buttons["recording-open-current"]
        let openLabel = openRecording.label
        XCTAssertTrue(openLabel.hasPrefix("Open recording, "))
        XCTAssertEqual(window.buttons["recording-stop"].label,"Stop recording")
        for key in ["w","q"] {
            app.typeKey(key,modifierFlags:.command)
            XCTAssertTrue(waitForPresent(window.sheets.staticTexts["A recording is running"],timeout:10),app.debugDescription)
            app.typeKey(.escape,modifierFlags:[])
            let stayed = NSPredicate { _,_ in window.exists && !window.sheets.firstMatch.exists && window.buttons["recording-page-stop"].exists }
            XCTAssertEqual(XCTWaiter.wait(for:[XCTNSPredicateExpectation(predicate:stayed,object:nil)],timeout:5),.completed,app.debugDescription)
        }
        let labelUpdated = NSPredicate(format:"exists == true AND label BEGINSWITH %@ AND label != %@", "Open recording, ", openLabel)
        let update = XCTNSPredicateExpectation(predicate:labelUpdated,object:openRecording)
        XCTAssertEqual(XCTWaiter.wait(for:[update],timeout:5),.completed,"Elapsed accessible time advances while the recording runs")
        title.click(); app.typeKey("a",modifierFlags:.command); title.typeText("Title from the live page")
        XCTAssertFalse(window.textViews["recording-notes"].exists)
        window.buttons.matching(identifier:"recording-back").firstMatch.click()
        window.buttons["recording-open-current"].click()
        XCTAssertTrue(waitForPresent(title,timeout:10))
        XCTAssertEqual(title.value as? String,"Title from the live page")
        XCTAssertFalse(window.textViews["recording-notes"].exists)
        app.typeKey("q",modifierFlags:.command)
        XCTAssertTrue(waitForPresent(window.sheets.buttons["Keep recording"],timeout:10),app.debugDescription)
        window.sheets.buttons["Keep recording"].click()
        let backgrounded = NSPredicate { _,_ in !window.exists }
        XCTAssertEqual(XCTWaiter.wait(for:[XCTNSPredicateExpectation(predicate:backgrounded,object:nil)],timeout:10),.completed,app.debugDescription)
        let status = app.descendants(matching:.any)["recording-menu-bar"]
        XCTAssertTrue(waitForPresent(status,timeout:10),app.debugDescription); status.click()
        let payload = app.staticTexts["recording-menu-fixture-payload"]
        XCTAssertTrue(waitForPresent(payload,timeout:10),app.debugDescription)
        let json = try XCTUnwrap(payload.value as? String)
        let data = try XCTUnwrap(json.data(using:.utf8))
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with:data) as? [String:Any])
        XCTAssertEqual(body["assertionHeld"] as? Bool,true)
        XCTAssertEqual(body["title"] as? String,"Title from the live page")
        XCTAssertEqual(body["noSleep"] as? String,"Your Mac will not sleep while Cassini records.")
        let actions = try XCTUnwrap(body["actions"] as? [[String:Any]])
        XCTAssertEqual(actions.compactMap { $0["id"] as? String },["stop","open","settings","quit"])
        XCTAssertEqual(actions.first?["shortcut"] as? String,"⌥⌘R")
        let dump = XCTAttachment(data:data,uniformTypeIdentifier:"public.json")
        dump.name = "recording-menu.json"; dump.lifetime = .keepAlways; add(dump)
        app.buttons["recording-menu-open"].click()
        XCTAssertTrue(waitForPresent(title,timeout:10))
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
        XCTAssertTrue(waitForPresent(window.buttons["recording-stop"],timeout:10),app.debugDescription)
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
        XCTAssertTrue(waitForPresent(window.buttons["first-run-record"],timeout: 20), app.debugDescription)
        window.buttons["first-run-record"].click()
        XCTAssertTrue(waitForPresent(window.sheets.buttons["record-first-start"],timeout: 10))
        window.sheets.buttons["record-first-start"].click()
        XCTAssertTrue(waitForPresent(window.buttons["recording-stop"],timeout: 10), app.debugDescription)
        let speech = NSPredicate { _, _ in self.recordedSeconds(window) >= 5 }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: speech, object: nil)], timeout: 10), .completed)
        window.buttons["recording-stop"].click()
        let retry = window.buttons["Try again"]
        XCTAssertTrue(waitForPresent(retry,timeout: 20), app.debugDescription)
        XCTAssertTrue(text("Could not write this meeting down. The audio is fine.", in: window))
        XCTAssertTrue(window.buttons["preview-play"].isEnabled)
        retry.click()
        // Partial words enable the button while the write-down still runs; the preview then
        // drops its transcribing line and the button moves. Click only once it has settled.
        let transcribing = window.descendants(matching: .any)["preview-transcribing"]
        let readable = NSPredicate { _, _ in window.buttons["preview-read-transcript"].isEnabled && !retry.exists && !transcribing.exists }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: readable, object: nil)], timeout: 40), .completed, app.debugDescription)
        window.buttons["preview-read-transcript"].click()
        XCTAssertTrue(waitForPresent(window.buttons["meeting-back"],timeout: 10))
        let me=window.buttons["speaker-name-me"]
        XCTAssertTrue(me.waitForExistence(timeout:10),app.debugDescription)
        XCTAssertTrue(me.label.hasPrefix("Me,"),me.label)
        XCTAssertFalse(window.buttons["meeting-write-down"].exists)
    }
    @MainActor func testQuitPausesWritingDownAndResumesOnRelaunch() throws {
        let base = ["--fixture-library-recording", "-CassiniCaptureID", UUID().uuidString, "-CassiniTranscriptionFixture", "YES"]
        var app = try launch("first-run",fixture:"empty",extra:base + ["-CassiniSlowTranscription","YES"])
        defer { if app.state != .notRunning { app.terminate() } }
        var window = app.windows["cassini-library-window"]
        XCTAssertTrue(waitForPresent(window.buttons["first-run-record"],timeout:20),app.debugDescription)
        window.buttons["first-run-record"].click()
        XCTAssertTrue(waitForPresent(window.sheets.buttons["record-first-start"],timeout:10))
        window.sheets.buttons["record-first-start"].click()
        XCTAssertTrue(waitForPresent(window.buttons["recording-stop"],timeout:10))
        let speech = NSPredicate { _,_ in self.recordedSeconds(window) >= 5 }
        XCTAssertEqual(XCTWaiter.wait(for:[XCTNSPredicateExpectation(predicate:speech,object:nil)],timeout:10),.completed)
        window.buttons["recording-stop"].click()
        XCTAssertTrue(waitForPresent(window.descendants(matching:.any)["Transcribing…"],timeout:10),app.debugDescription)
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
        let nameSpeakers = window.buttons["name-the-speakers"]
        XCTAssertTrue(nameSpeakers.exists)
        XCTAssertFalse(nameSpeakers.isEnabled, "The static screenshot fixture is read-only")
        XCTAssertEqual(title.frame.minX - window.frame.minX, 280, accuracy: 16)
        capture(window, name: "meeting")
        for value in ["Marta", "Giulia Rossi", "Speaker 3", "43%", "36%", "21%", "00:03:12", "00:47:05"] {
            XCTAssertTrue(text(value, in: window), value)
        }
        // D70 combines provenance and turn timing, and the narrow visual text
        // may truncate. Read-only speaker rows stay plain content (not dimmed
        // disabled buttons) while keeping Play on the name/share line so the
        // caption keeps the full row width.
        for (speaker,provenance) in [("marta","Named by you"),("giulia","Recognised from saved voices"),("guest","Not named yet")] {
            XCTAssertFalse(window.buttons["speaker-name-" + speaker].exists,"Read-only speaker rows must not render as disabled buttons")
            let row = window.descendants(matching:.any).matching(identifier:"speaker-row-" + speaker).firstMatch
            XCTAssertTrue(row.waitForExistence(timeout:5),speaker)
            XCTAssertTrue(row.label.contains(provenance),row.label)
            let caption = window.descendants(matching:.any).matching(identifier:"speaker-caption-" + speaker).firstMatch
            XCTAssertTrue(caption.exists,speaker)
            XCTAssertGreaterThanOrEqual(caption.frame.width,185,"Caption keeps full row width without an outer Play column")
        }
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
    @MainActor func launch(_ name: String, fixture: String, extra: [String] = [], language:String="en-GB",locale:String="en_GB") throws -> XCUIApplication {
        let app = XCUIApplication()
        let root = try fixtureDirectory().appendingPathComponent("Library/" + fixture)
        let dark = ProcessInfo.processInfo.environment["CASSINI_SCREENSHOT_SCHEME"] == "dark"
        app.launchEnvironment["CASSINI_HOSTED_SCREENSHOTS"] = "1"
        app.launchArguments = ["-CassiniScreenshot", name, "-CassiniFixture", root.path,
                               "-CassiniNow", "2026-10-27T13:18:00Z", "-ApplePersistenceIgnoreState", "YES",
                               "-AppleLanguages", "(\(language))", "-AppleLocale", locale, "-AppleInterfaceStyle", dark ? "Dark" : "Light"]
        if let accent = ProcessInfo.processInfo.environment["CASSINI_SCREENSHOT_ACCENT"], !accent.isEmpty {
            app.launchArguments += ["-AppleAccentColor", accent]
        }
        if dark { app.launchArguments += ["-CassiniScreenshotScheme", "dark"] }
        if !extra.contains("-CassiniSettingsID") && !extra.contains("-CassiniCaptureID") && !extra.contains("-CassiniDefaultsID") {
            app.launchArguments += ["-CassiniDefaultsID", UUID().uuidString]
        }
        app.launchArguments += extra
        if extra.contains("--fixture-library-recording"), !extra.contains("-CassiniDiskFree") {
            app.launchArguments += ["-CassiniDiskFree",String(20 << 30),"-CassiniDiskTotal",String(100 << 30)]
        }
        app.launch()
        if extra.contains("--fixture-library-recording") || extra.contains("--fixture-library-rename"),
           !app.windows.firstMatch.waitForExistence(timeout: 2) {
            app.menuBars.menuBarItems["Window"].click()
            app.menuBars.menuBarItems["Window"].menus.menuItems["Cassini talk"].click()
        }
        return app
    }
    @MainActor private func board(_ name: String, fixture: String) throws {
        let app = try launch(name, fixture: fixture); defer { app.terminate() }
        let window = app.windows["cassini-library-window"]
        XCTAssertTrue(window.waitForExistence(timeout: 20), app.debugDescription)
        // The custom toolbar hides the window title, so its AX label is empty.
        // Window's own menu still exposes the actual NSWindow title.
        app.menuBars.menuBarItems["Window"].click()
        XCTAssertTrue(app.menuItems["Cassini talk"].exists, app.debugDescription)
        app.typeKey(.escape, modifierFlags: [])
        let productMenu = app.menuBars.menuBarItems["Cassini talk"]
        XCTAssertTrue(productMenu.exists, app.debugDescription)
        productMenu.click()
        XCTAssertTrue(app.menuItems["About Cassini talk"].exists, app.debugDescription)
        XCTAssertTrue(app.menuItems["Check for Updates…"].exists, app.debugDescription)
        app.typeKey(.escape, modifierFlags: [])
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
            XCTAssertTrue(text("52 min", in: window), window.debugDescription)
            XCTAssertTrue(text("Marta, Dario, Speaker 3", in: window), window.debugDescription)
            XCTAssertTrue(text("Today, 09:00 · 52 min", in: window), window.debugDescription)
            XCTAssertTrue(text("00:00:04", in: window))
            XCTAssertTrue(text("Listening inside your browser", in: window))
            XCTAssertTrue(window.buttons["toolbar-import"].exists, window.debugDescription)
            XCTAssertEqual(window.buttons["toolbar-import"].label, "Import Audio…")
            XCTAssertTrue(text("Drop audio files here to import", in: window), window.debugDescription)
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
