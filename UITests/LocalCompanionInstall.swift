// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import XCTest
import CoreGraphics

/// Real manual-install flow on a disposable hosted Mac. No extension-loading
/// flags, profile injection, fake peers or capture APIs participate in this gate.
final class LocalCompanionInstall: XCTestCase {
    @MainActor func testFreshBrowserCopyAddressInstallAndNewerAppFolder() throws {
        let env = ProcessInfo.processInfo.environment
        guard env["CASSINI_LOCAL_GUIDE_GATE"] == "1", let configPath = env["CASSINI_LOCAL_GUIDE_CONFIG"] else {
            throw XCTSkip("Hosted local-companion job only")
        }
        let config = try JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:configPath))) as! [String:String]
        func value(_ key: String) throws -> String { try XCTUnwrap(config[key],key) }
        let installed = URL(fileURLWithPath:try value("installed")), output = URL(fileURLWithPath:try value("output"))
        let chrome = XCUIApplication(url:URL(fileURLWithPath:try value("browser")))
        chrome.launchArguments = ["--user-data-dir=" + (try value("profile")), "--no-first-run", "--no-default-browser-check",
            "--disable-background-networking", "--force-renderer-accessibility",
            "--host-resolver-rules=MAP * ~NOTFOUND, EXCLUDE localhost", "about:blank"]
        let app = XCUIApplication(url:URL(fileURLWithPath:try value("app")))
        configure(app)
        defer {
            for (name,application) in [("cassini",app),("chromium",chrome)] {
                let tree = XCTAttachment(string:application.debugDescription); tree.name = name+"-final-tree"; tree.lifetime = .keepAlways; add(tree)
                if application.state != .notRunning { attach(application,name:name+"-final"); application.terminate() }
            }
        }
        addUIInterruptionMonitor(withDescription:"Hosted setup interruption diagnostics") { alert in
            print("Hosted interruption: " + alert.debugDescription)
            return false // Preserve XCTest's normal handling; grant nothing here.
        }
        chrome.launch()
        app.launch()
        app.typeKey(",",modifierFlags:.command)
        let settings = app.windows["cassini-settings-window"]
        XCTAssertTrue(settings.waitForExistence(timeout:10),app.debugDescription)
        settings.toolbars.buttons["Browser companion"].click()
        let addButton = settings.buttons["browser-add"]
        XCTAssertTrue(addButton.waitForExistence(timeout:15),app.debugDescription)
        wait("Supported browser discovered") { addButton.isEnabled }
        XCTAssertEqual(addButton.label,"Add from Cassini")
        addButton.click()
        let guide = settings.sheets.firstMatch
        XCTAssertTrue(guide.buttons["companion-copy-address"].waitForExistence(timeout:10),app.debugDescription)
        guide.descendants(matching:.any).matching(identifier:"companion-browser-choice").firstMatch.click()
        app.menuItems["Chrome for Testing"].click()
        let done = guide.buttons["companion-local-done"]
        XCTAssertFalse(done.isEnabled,"A prepared folder alone is not a native handshake")
        attach(app,name:"companion-local-guide")
        guide.buttons["companion-copy-address"].click()
        XCTAssertEqual(NSPasteboard.general.string(forType:.string),"chrome://extensions/")
        print("Browser focus: XCTest=\(chrome.state.rawValue), frontmost=\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "none"), postAccess=\(CGPreflightPostEventAccess())")
        chrome.activate()
        // The test person selects the browser's title bar before pasting.
        // Its native address-field value below proves the actual paste target.
        chrome.windows.firstMatch.coordinate(withNormalizedOffset:CGVector(dx:0.5,dy:0.01)).click()
        key(0x25,flags:.maskCommand) // L
        key(0x09,flags:.maskCommand) // V
        let address = chrome.textFields["Address and search bar"]
        wait("Chromium receives the copied Extensions address") { (address.value as? String)?.hasPrefix("chrome://extensions") == true }
        key(0x24) // Return
        // Chromium has exposed cr-toggle as checkbox, switch and pressed button
        // across releases. The action and accessible name stay the same.
        let toggles = [chrome.checkBoxes["Developer mode"],chrome.switches["Developer mode"],chrome.buttons["Developer mode"]]
        wait("Extensions Developer mode control",timeout:20) { toggles.contains { $0.exists } }
        let developer = try XCTUnwrap(toggles.first { $0.exists },chrome.debugDescription)
        if !chrome.buttons["Load unpacked"].exists { developer.click() }
        let load = chrome.buttons["Load unpacked"]
        XCTAssertTrue(load.waitForExistence(timeout:10),chrome.debugDescription)
        app.activate()
        let copy = guide.buttons["companion-copy-folder"]
        wait("Bundled folder prepared by the real helper") { copy.isEnabled }
        copy.click()
        XCTAssertEqual(NSPasteboard.general.string(forType:.string),installed.path)
        XCTAssertFalse(done.isEnabled)
        chrome.activate()
        load.click()
        let choose = chrome.buttons["OKButton"]
        XCTAssertTrue(choose.waitForExistence(timeout:10),chrome.debugDescription)
        key(0x05,flags:[.maskCommand,.maskShift]) // G
        key(0x09,flags:.maskCommand)
        key(0x24)
        choose.click()
        let extensionID = "pcafdaahfhjiolfpfnlhmljfgoabbaij"
        let identity = chrome.staticTexts.matching(NSPredicate(format:"value CONTAINS %@ OR label CONTAINS %@",extensionID,extensionID)).firstMatch
        XCTAssertTrue(identity.waitForExistence(timeout:20),chrome.debugDescription)
        attach(chrome,name:"companion-local-loaded-id")
        app.activate()
        wait("Real native messaging handshake enables Done",timeout:50) { done.isEnabled }
        attach(app,name:"companion-local-connected")
        done.click()
        XCTAssertFalse(guide.exists)
        app.terminate(); chrome.terminate()

        // The next app is a private copy of this signed product with only its
        // bundled manifest/build version advanced. Shared CI products stay sealed.
        let next = XCUIApplication(url:URL(fileURLWithPath:try value("nextApp")))
        configure(next)
        defer { if next.state != .notRunning { next.terminate() } }
        let expectedVersion = try value("newVersion")
        let manifest = installed.appendingPathComponent("manifest.json")
        next.launch()
        wait("New app replaces the stable folder") {
            guard let data = try? Data(contentsOf:manifest), let object = try? JSONSerialization.jsonObject(with:data) as? [String:Any] else { return false }
            return object["version"] as? String == expectedVersion
        }
        let before = try FileManager.default.attributesOfItem(atPath:manifest.path)
        next.terminate(); next.launch()
        // A second actual launch must finish its preparation without rewriting
        // the equal-version copy. Observe the product's real Copy folder state.
        next.typeKey(",",modifierFlags:.command)
        let nextSettings = next.windows["cassini-settings-window"]
        XCTAssertTrue(nextSettings.waitForExistence(timeout:10))
        nextSettings.toolbars.buttons["Browser companion"].click()
        let nextAdd = nextSettings.buttons["browser-add"]
        wait("Updated app discovers the installed browser") { nextAdd.isEnabled }
        nextAdd.click()
        wait("Repeat launch preparation finished") { nextSettings.sheets.buttons["companion-copy-folder"].isEnabled }
        let after = try FileManager.default.attributesOfItem(atPath:manifest.path)
        XCTAssertEqual(before[.systemFileNumber] as? NSNumber,after[.systemFileNumber] as? NSNumber)
        XCTAssertEqual(before[.modificationDate] as? Date,after[.modificationDate] as? Date)
        let report: [String:Any] = ["freshProfile":true,"copyAddressFlow":true,"extensionLoadFlags":false,
            "profileInjection":false,"storeDNSDisabled":true,"loadedID":extensionID,"realNativeHandshake":true,
            "newerAppFolderReplaced":true,"repeatLaunchDidNotRewrite":true,"newVersion":expectedVersion,"audioCaptured":false]
        try JSONSerialization.data(withJSONObject:report,options:[.sortedKeys,.prettyPrinted]).write(to:output)
    }
    @MainActor private func configure(_ app: XCUIApplication) {
        app.launchEnvironment["CASSINI_HOSTED_SCREENSHOTS"] = "1"
        app.launchArguments = ["--fixture-library-rename","-CassiniRenameID",UUID().uuidString,
            "-ApplePersistenceIgnoreState","YES","-AppleLanguages","(en-GB)","-AppleLocale","en_GB"]
    }
    @MainActor private func wait(_ message: String, timeout: TimeInterval = 25, condition: @escaping () -> Bool) {
        let predicate = NSPredicate { _,_ in condition() }
        XCTAssertEqual(XCTWaiter.wait(for:[XCTNSPredicateExpectation(predicate:predicate,object:nil)],timeout:timeout),.completed,message)
    }
    @MainActor private func attach(_ app: XCUIApplication, name: String) {
        let screenshot = XCTAttachment(screenshot:app.screenshot()); screenshot.name = name; screenshot.lifetime = .keepAlways; add(screenshot)
    }
    @MainActor private func key(_ code: CGKeyCode, flags: CGEventFlags = []) {
        // XCTest's app-directed typeKey stalls without delivering keys to this
        // pinned Chromium. Send test-person HID events on the hosted desktop.
        guard let path = ProcessInfo.processInfo.environment["CASSINI_LOCAL_GUIDE_KEYS"] else { XCTFail("Missing hosted keyboard helper"); return }
        let process = Process(); process.executableURL = URL(fileURLWithPath:"/usr/bin/sudo")
        process.arguments = [path,String(code),String(flags.rawValue)]
        do { try process.run(); process.waitUntilExit(); XCTAssertEqual(process.terminationStatus,0) }
        catch { XCTFail("Hosted keyboard failed: \(error)") }
    }
}
