// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import XCTest

/// Changes the actual hosted OS setting. No renderer override or synthetic
/// NSWorkspace notification can satisfy the probe's production observer check.
final class SpectrogramMotion: XCTestCase {
    @MainActor private func state(_ control:XCUIElement) -> Bool? {
        if let value=control.value as? String {
            if value == "1" { return true };if value == "0" { return false }
        }
        if let value=control.value as? NSNumber {
            if value.intValue == 1 { return true };if value.intValue == 0 { return false }
        }
        return nil
    }
    @MainActor func testRealSystemSettingsMotionTransitions() throws {
        let environment=ProcessInfo.processInfo.environment
        guard environment["CASSINI_SPECTRO_MOTION_GATE"] == "1",
              let path=environment["CASSINI_SPECTRO_MOTION_REQUEST"] else {
            throw XCTSkip("Disposable spectrogram measurement only")
        }
        let requestURL=URL(fileURLWithPath:path)
        let settings=XCUIApplication(bundleIdentifier:"com.apple.systempreferences")
        defer { if settings.state != .notRunning { settings.terminate() } }
        for expected in [true,false] {
            var request:[String:Any]?
            let arrived=NSPredicate { _,_ in
                guard let bytes=try? Data(contentsOf:requestURL),
                      let body=try? JSONSerialization.jsonObject(with:bytes) as? [String:Any],
                      body["reduceMotion"] as? Bool == expected else { return false }
                request=body;return true
            }
            XCTAssertEqual(XCTWaiter.wait(for:[XCTNSPredicateExpectation(predicate:arrived,object:nil)],timeout:120),.completed,"Probe requested the next OS setting")
            let body=try XCTUnwrap(request)
            settings.launch()
            let pane=try XCTUnwrap(URL(string:"x-apple.systempreferences:com.apple.Accessibility-Settings.extension?Display"))
            XCTAssertTrue(NSWorkspace.shared.open(pane))
            // macOS15 exposes the label as a separate static text, while its
            // switch has this identifier and no label. Verified in the real
            // hosted AX tree, rather than guessing from the visible caption.
            let controls=[settings.switches["AX_REDUCE_MOTION"],settings.checkBoxes["Reduce motion"],settings.switches["Reduce motion"],settings.buttons["Reduce motion"]]
            let exists=NSPredicate { _,_ in controls.contains { $0.exists } }
            XCTAssertEqual(XCTWaiter.wait(for:[XCTNSPredicateExpectation(predicate:exists,object:nil)],timeout:20),.completed,settings.debugDescription)
            let control=try XCTUnwrap(controls.first { $0.exists },settings.debugDescription)
            if try XCTUnwrap(state(control),"System setting exposes a binary value") != expected { control.click() }
            let changed=NSPredicate { _,_ in self.state(control) == expected }
            XCTAssertEqual(XCTWaiter.wait(for:[XCTNSPredicateExpectation(predicate:changed,object:nil)],timeout:10),.completed,settings.debugDescription)
            let attachment=XCTAttachment(screenshot:settings.screenshot())
            attachment.name=expected ? "system-reduce-motion-on":"system-reduce-motion-off"
            attachment.lifetime = .keepAlways;add(attachment)
            settings.terminate()
            let pid=try XCTUnwrap(body["pid"] as? Int32)
            XCTAssertTrue(NSRunningApplication(processIdentifier:pid)?.activate(options:[.activateIgnoringOtherApps]) == true)
        }
    }
}
