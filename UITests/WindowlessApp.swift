// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import XCTest

extension LibraryBoards {
    @MainActor func testIdleMenuPreferenceWindowlessSettingsAndDockReopen() async throws {
        let app = try launch("first-run",fixture:"empty",extra:["--fixture-library-recording","-CassiniCaptureID",UUID().uuidString])
        defer { app.terminate() }
        let library = app.windows["cassini-library-window"]
        XCTAssertTrue(library.waitForExistence(timeout:20),app.debugDescription)
        XCTAssertFalse(app.descendants(matching:.any)["idle-menu-bar"].exists)
        app.typeKey(",",modifierFlags:.command)
        let settings = app.windows["cassini-settings-window"]
        let show = settings.descendants(matching:.any).matching(identifier:"settings-show-menu-bar").matching(NSPredicate(format:"value != nil")).firstMatch
        let auto = settings.descendants(matching:.any).matching(identifier:"settings-auto-record").matching(NSPredicate(format:"value != nil")).firstMatch
        XCTAssertTrue(show.waitForExistence(timeout:10),app.debugDescription)
        XCTAssertEqual(String(describing:try XCTUnwrap(show.value)),"1","Idle item defaults on")
        XCTAssertEqual(String(describing:try XCTUnwrap(auto.value)),"0")
        auto.click()
        let idle = app.descendants(matching:.any)["idle-menu-bar"]
        XCTAssertTrue(idle.waitForExistence(timeout:10),app.debugDescription)
        settings.buttons["_XCUI:CloseWindow"].click()
        library.buttons["_XCUI:CloseWindow"].click()
        waitForWindowless { !library.exists && !settings.exists }
        XCTAssertNotEqual(app.state,.notRunning)
        idle.click()
        XCTAssertTrue(app.staticTexts["Ready to record browser meetings"].waitForExistence(timeout:5),app.debugDescription)
        app.buttons["idle-menu-open"].click()
        XCTAssertTrue(library.waitForExistence(timeout:10),app.debugDescription)
        library.buttons["_XCUI:CloseWindow"].click()
        waitForWindowless { !library.exists }
        idle.click()
        XCTAssertTrue(app.buttons["idle-menu-open"].waitForExistence(timeout:5))
        // LaunchServices sends the same reopen event as clicking the Dock icon,
        // unlike XCUIApplication.activate(), which only activates the process.
        let bundle = try XCTUnwrap(NSRunningApplication.runningApplications(withBundleIdentifier:"io.codemyriad.cassini").first?.bundleURL)
        try await withCheckedThrowingContinuation { (reply: CheckedContinuation<Void,Error>) in
            NSWorkspace.shared.openApplication(at:bundle,configuration:NSWorkspace.OpenConfiguration()) { _,error in
                if let error { reply.resume(throwing:error) } else { reply.resume() }
            }
        }
        XCTAssertTrue(library.waitForExistence(timeout:10),app.debugDescription)
        XCTAssertEqual(app.windows.matching(identifier:"cassini-library-window").count,1)
        // Dock reopen may leave the already-expanded status popup in place.
        // Clicking its label again would close it instead of opening Settings.
        if !app.buttons["idle-menu-settings"].exists { idle.click() }
        XCTAssertTrue(app.buttons["idle-menu-settings"].waitForExistence(timeout:5),app.debugDescription)
        app.buttons["idle-menu-settings"].click()
        XCTAssertTrue(show.waitForExistence(timeout:10),app.debugDescription)
        show.click()
        waitForWindowless { !idle.exists }
        XCTAssertEqual(String(describing:try XCTUnwrap(auto.value)),"1","Hiding the idle item does not disable automatic recording")
        app.terminate(); app.launch()
        // Normal launch must recover on its own, without Window > Library.
        XCTAssertTrue(library.waitForExistence(timeout:20),app.debugDescription)
        XCTAssertFalse(idle.exists,"The hidden-idle preference persists")
        app.typeKey(",",modifierFlags:.command)
        XCTAssertTrue(show.waitForExistence(timeout:10)); XCTAssertEqual(String(describing:try XCTUnwrap(show.value)),"0")
        show.click(); XCTAssertTrue(idle.waitForExistence(timeout:10))
        auto.click(); waitForWindowless { !idle.exists }
        auto.click(); XCTAssertTrue(idle.waitForExistence(timeout:10))
        settings.buttons["_XCUI:CloseWindow"].click(); library.buttons["_XCUI:CloseWindow"].click()
        waitForWindowless { !library.exists && !settings.exists }
        idle.click(); app.buttons["idle-menu-quit"].click()
        waitForWindowless { app.state == .notRunning }
    }

    @MainActor func testWindowlessRecordingMenuQuitSavesEvenWithIdleItemHidden() throws {
        let app = try launch("first-run",fixture:"empty",extra:["--fixture-library-recording","-CassiniCaptureID",UUID().uuidString])
        defer { app.terminate() }
        let library = app.windows["cassini-library-window"]
        XCTAssertTrue(library.waitForExistence(timeout:20))
        app.typeKey(",",modifierFlags:.command)
        let settings = app.windows["cassini-settings-window"]
        let show = settings.descendants(matching:.any).matching(identifier:"settings-show-menu-bar").matching(NSPredicate(format:"value != nil")).firstMatch
        XCTAssertTrue(show.waitForExistence(timeout:10)); show.click()
        settings.buttons["_XCUI:CloseWindow"].click()
        library.buttons["first-run-record"].click()
        XCTAssertTrue(app.buttons["record-first-start"].waitForExistence(timeout:10)); app.buttons["record-first-start"].click()
        XCTAssertTrue(library.buttons["recording-stop"].waitForExistence(timeout:10),app.debugDescription)
        let finder=XCUIApplication(bundleIdentifier:"com.apple.finder")
        let firstStatus=app.descendants(matching:.any)["recording-menu-bar"]
        XCTAssertTrue(firstStatus.waitForExistence(timeout:10))
        finder.activate();backgroundClick(firstStatus,through:finder)
        XCTAssertTrue(app.buttons["recording-menu-quit"].waitForExistence(timeout:5))
        backgroundClick(app.buttons["recording-menu-quit"],through:finder)
        XCTAssertTrue(library.sheets.buttons["Stop and keep it"].waitForExistence(timeout:10))
        waitForWindowless { NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "io.codemyriad.cassini" }
        app.typeKey(.escape,modifierFlags:[])
        waitForWindowless { !library.sheets.firstMatch.exists }
        app.typeKey("q",modifierFlags:.command)
        let background = library.sheets.firstMatch.buttons["Keep recording"]
        XCTAssertTrue(background.waitForExistence(timeout:10)); background.click()
        waitForWindowless { !library.exists }
        let status = app.descendants(matching:.any)["recording-menu-bar"]
        XCTAssertTrue(status.waitForExistence(timeout:10),"The idle preference never hides a recording")
        status.click()
        let payload = app.staticTexts["recording-menu-fixture-payload"]
        XCTAssertTrue(payload.waitForExistence(timeout:10))
        let json = try XCTUnwrap((payload.value as? String)?.data(using:.utf8))
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with:json) as? [String:Any])
        let folder = URL(fileURLWithPath:try XCTUnwrap(body["fixtureDirectory"] as? String))
        app.buttons["recording-menu-settings"].click()
        XCTAssertTrue(show.waitForExistence(timeout:10)); XCTAssertEqual(String(describing:try XCTUnwrap(show.value)),"0")
        settings.buttons["_XCUI:CloseWindow"].click()
        // Target coordinates through Finder so XCTest cannot activate Cassini
        // for us before the product's menu action does so.
        finder.activate();backgroundClick(status,through:finder)
        XCTAssertTrue(app.buttons["recording-menu-quit"].waitForExistence(timeout:5))
        backgroundClick(app.buttons["recording-menu-quit"],through:finder)
        let keep = app.dialogs.firstMatch.buttons["Stop and keep it"]
        XCTAssertTrue(keep.waitForExistence(timeout:10),app.debugDescription)
        waitForWindowless { NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "io.codemyriad.cassini" }
        XCTAssertFalse(library.exists,"Windowless Quit presents its own dialog, not a sheet on a disappearing menu")
        app.typeKey(.escape,modifierFlags:[])
        waitForWindowless { !keep.exists }
        XCTAssertTrue(status.exists,"Escape cancels Quit and keeps recording")
        finder.activate();backgroundClick(status,through:finder)
        XCTAssertTrue(app.buttons["recording-menu-quit"].waitForExistence(timeout:5))
        backgroundClick(app.buttons["recording-menu-quit"],through:finder)
        XCTAssertTrue(keep.waitForExistence(timeout:10))
        waitForWindowless { NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "io.codemyriad.cassini" }
        app.typeKey(.return,modifierFlags:[])
        waitForWindowless { app.state == .notRunning }
        let saved = try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:folder.appendingPathComponent("session.json"))) as? [String:Any])
        XCTAssertEqual(saved["state"] as? String,"completed")
        let tracks = try XCTUnwrap(saved["tracks"] as? [[String:Any]])
        XCTAssertFalse(tracks.isEmpty)
        for track in tracks {
            XCTAssertGreaterThan((track["frames"] as? NSNumber)?.int64Value ?? 0,0)
            let file = folder.appendingPathComponent(try XCTUnwrap(track["file"] as? String))
            XCTAssertGreaterThan(try Data(contentsOf:file).count,44)
        }
    }

    @MainActor func testColdWindowlessRelaunchOpensFromDockAndBothMenus() async throws {
        let app=try launch("first-run",fixture:"empty",extra:["--fixture-library-recording","-CassiniCaptureID",UUID().uuidString])
        defer { app.terminate() }
        let library=app.windows["cassini-library-window"]
        app.typeKey(",",modifierFlags:.command)
        let settings=app.windows["cassini-settings-window"]
        let auto=settings.descendants(matching:.any).matching(identifier:"settings-auto-record").matching(NSPredicate(format:"value != nil")).firstMatch
        XCTAssertTrue(auto.waitForExistence(timeout:10));auto.click()
        settings.buttons["_XCUI:CloseWindow"].click();library.buttons["_XCUI:CloseWindow"].click()
        let idle=app.descendants(matching:.any)["idle-menu-bar"]
        XCTAssertTrue(idle.waitForExistence(timeout:10));idle.click()
        app.buttons["idle-menu-quit"].click();waitForWindowless { app.state == .notRunning }
        app.launchArguments.append("--fixture-windowless-launch")
        // Suppress only the test's initial scene presentation. Each fresh
        // process must route requests before any Library onAppear has run.
        for route in ["dock","idle"] {
            app.launch();XCTAssertTrue(idle.waitForExistence(timeout:10))
            XCTAssertFalse(library.exists,"Cold launch has no mounted Library")
            if route == "dock" { try await dockReopen(app) }
            else { idle.click();app.buttons["idle-menu-open"].click() }
            XCTAssertTrue(library.waitForExistence(timeout:15),app.debugDescription)
            XCTAssertEqual(app.windows.matching(identifier:"cassini-library-window").count,1)
            library.buttons["_XCUI:CloseWindow"].click()
            waitForWindowless { !library.exists }
            idle.click();app.buttons["idle-menu-quit"].click();waitForWindowless { app.state == .notRunning }
        }
        // No menu-bar host and no Library view: Dock routing still works.
        app.launch();XCTAssertTrue(idle.waitForExistence(timeout:10))
        idle.click();app.buttons["idle-menu-open"].click()
        XCTAssertTrue(library.waitForExistence(timeout:15))
        app.typeKey(",",modifierFlags:.command)
        let show=settings.descendants(matching:.any).matching(identifier:"settings-show-menu-bar").matching(NSPredicate(format:"value != nil")).firstMatch
        XCTAssertTrue(show.waitForExistence(timeout:10));show.click()
        settings.buttons["_XCUI:CloseWindow"].click();library.buttons["_XCUI:CloseWindow"].click()
        app.typeKey("q",modifierFlags:.command);waitForWindowless { app.state == .notRunning }
        app.launch();XCTAssertFalse(idle.waitForExistence(timeout:2));XCTAssertFalse(library.exists)
        try await dockReopen(app)
        XCTAssertTrue(library.waitForExistence(timeout:15),app.debugDescription)
        app.typeKey(",",modifierFlags:.command);XCTAssertTrue(show.waitForExistence(timeout:10));show.click()
        settings.buttons["_XCUI:CloseWindow"].click();library.buttons["_XCUI:CloseWindow"].click()
        idle.click();app.buttons["idle-menu-quit"].click();waitForWindowless { app.state == .notRunning }
        app.launchArguments.append("--fixture-recording-on-launch")
        app.launch()
        let recording=app.descendants(matching:.any)["recording-menu-bar"]
        XCTAssertTrue(recording.waitForExistence(timeout:15),app.debugDescription)
        XCTAssertFalse(library.exists)
        recording.click();XCTAssertTrue(app.buttons["recording-menu-open"].waitForExistence(timeout:5))
        app.buttons["recording-menu-open"].click()
        XCTAssertTrue(library.waitForExistence(timeout:15),app.debugDescription)
        XCTAssertTrue(library.buttons["recording-stop"].waitForExistence(timeout:15),app.debugDescription)
        library.buttons["recording-stop"].click()
        XCTAssertTrue(library.buttons["preview-play"].waitForExistence(timeout:15))
    }

    @MainActor func testInsertedIdleMenuTracksRecordingStartAndStop() throws {
        let app=try launch("first-run",fixture:"empty",extra:["--fixture-library-recording","-CassiniCaptureID",UUID().uuidString])
        defer { app.terminate() }
        let library=app.windows["cassini-library-window"]
        app.typeKey(",",modifierFlags:.command)
        let settings=app.windows["cassini-settings-window"]
        let auto=settings.descendants(matching:.any).matching(identifier:"settings-auto-record").matching(NSPredicate(format:"value != nil")).firstMatch
        XCTAssertTrue(auto.waitForExistence(timeout:10));auto.click()
        settings.buttons["_XCUI:CloseWindow"].click()
        let idle=app.descendants(matching:.any)["idle-menu-bar"]
        XCTAssertTrue(idle.waitForExistence(timeout:10));idle.click()
        XCTAssertTrue(app.buttons["idle-menu-open"].waitForExistence(timeout:5))
        library.buttons["first-run-record"].click()
        XCTAssertTrue(app.buttons["record-first-start"].waitForExistence(timeout:10));app.buttons["record-first-start"].click()
        let recording=app.descendants(matching:.any)["recording-menu-bar"]
        XCTAssertTrue(recording.waitForExistence(timeout:15));XCTAssertFalse(idle.exists)
        recording.click();XCTAssertTrue(app.buttons["recording-menu-stop"].waitForExistence(timeout:5))
        XCTAssertFalse(app.buttons["idle-menu-open"].exists)
        app.buttons["recording-menu-stop"].click()
        XCTAssertTrue(idle.waitForExistence(timeout:15));XCTAssertFalse(recording.exists)
        idle.click();XCTAssertTrue(app.buttons["idle-menu-open"].waitForExistence(timeout:5))
        XCTAssertFalse(app.buttons["recording-menu-stop"].exists)
    }

    @MainActor func testDockReopenKeepsMinimizedMeetingAndSearchState() async throws {
        let app=try launch("meeting",fixture:"main");defer { app.terminate() }
        let window=app.windows["cassini-library-window"]
        XCTAssertTrue(window.buttons["meeting-back"].waitForExistence(timeout:15))
        window.buttons["_XCUI:MinimizeWindow"].click()
        try await dockReopen(app)
        XCTAssertTrue(window.buttons["meeting-back"].waitForExistence(timeout:10),"Minimized meeting stays open")
        waitForWindowless { window.buttons["meeting-back"].isHittable }
        window.buttons["meeting-back"].click()
        app.typeKey("f",modifierFlags:.command);app.typeText("budget")
        let field=window.searchFields["library-search-field"]
        XCTAssertEqual(field.value as? String,"budget")
        window.buttons["_XCUI:MinimizeWindow"].click()
        try await dockReopen(app)
        XCTAssertTrue(field.waitForExistence(timeout:10));waitForWindowless { field.isHittable }
        XCTAssertEqual(field.value as? String,"budget")
    }

    @MainActor private func dockReopen(_ app:XCUIApplication) async throws {
        let name=try XCTUnwrap(NSRunningApplication.runningApplications(withBundleIdentifier:"io.codemyriad.cassini").first?.localizedName)
        // Exercise the actual Dock activation/minimized-window path. A
        // successful openApplication reply only acknowledges the launch request;
        // it does not prove that the Dock's restore action was performed.
        // The idle-menu test above retains independent LaunchServices coverage.
        let dock=XCUIApplication(bundleIdentifier:"com.apple.dock")
        let icon=dock.dockItems[name]
        XCTAssertTrue(icon.waitForExistence(timeout:10),dock.debugDescription)
        icon.click()
    }
    @MainActor private func backgroundClick(_ target:XCUIElement,through foreground:XCUIApplication) {
        let anchor=foreground.menuBars.firstMatch
        XCTAssertTrue(anchor.exists,"Foreground app has a real menu-bar coordinate anchor")
        let frame=target.frame,origin=anchor.frame.origin
        anchor.coordinate(withNormalizedOffset:.zero).withOffset(CGVector(dx:frame.midX-origin.x,dy:frame.midY-origin.y)).click()
    }

    @MainActor private func waitForWindowless(file: StaticString = #filePath, line: UInt = #line, _ condition: @escaping () -> Bool) {
        XCTAssertEqual(XCTWaiter.wait(for:[XCTNSPredicateExpectation(predicate:NSPredicate { _,_ in condition() },object:nil)],timeout:15),.completed,file:file,line:line)
    }
}
