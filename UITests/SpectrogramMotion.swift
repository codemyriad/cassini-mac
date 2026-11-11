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
    @MainActor private func motionControl(_ settings: XCUIApplication) throws -> XCUIElement {
        settings.launch()
        // macOS 27 moved Reduce motion out of Display into its own Motion pane.
        // The real 27 Display AX tree contains contrast/transparency, not motion.
        let section: String
        if #available(macOS 27.0, *) { section = "Motion" } else { section = "Display" }
        let pane=try XCTUnwrap(URL(string:"x-apple.systempreferences:com.apple.Accessibility-Settings.extension?\(section)"))
        XCTAssertTrue(NSWorkspace.shared.open(pane))
        // macOS15 exposes the label as a separate static text, while its
        // switch has this identifier and no label. Verified in the real
        // hosted AX tree, rather than guessing from the visible caption.
        let controls=[settings.switches["AX_REDUCE_MOTION"],settings.checkBoxes["Reduce motion"],settings.switches["Reduce motion"],settings.buttons["Reduce motion"]]
        let exists=NSPredicate { _,_ in controls.contains { $0.exists } }
        XCTAssertEqual(XCTWaiter.wait(for:[XCTNSPredicateExpectation(predicate:exists,object:nil)],timeout:20),.completed,settings.debugDescription)
        let control=try XCTUnwrap(controls.first { $0.exists },settings.debugDescription)
        return control
    }
    @MainActor func testRealSystemSettingsMotionTransitions() async throws {
        let environment=ProcessInfo.processInfo.environment
        guard environment["CASSINI_SPECTRO_MOTION_GATE"] == "1",
              let path=environment["CASSINI_SPECTRO_MOTION_REQUEST"] else {
            throw XCTSkip("Disposable spectrogram measurement only")
        }
        let requestURL=URL(fileURLWithPath:path)
        let settings=XCUIApplication(bundleIdentifier:"com.apple.systempreferences")
        defer { if settings.state != .notRunning { settings.terminate() } }
        // A XCTest "started" line precedes setup/automation readiness. Initialize
        // the actual Settings/AX path before the uninstrumented pacing interval.
        // An explicit event, not a settling delay, releases the measurement.
        let initial = try motionControl(settings)
        if try XCTUnwrap(state(initial)) { initial.click() }
        let normal = NSPredicate { _,_ in self.state(initial) == false }
        let ready = XCTWaiter.wait(for:[XCTNSPredicateExpectation(predicate:normal,object:nil)],timeout:10)
        XCTAssertEqual(ready,.completed)
        guard ready == .completed else { return }
        settings.terminate()
        FileHandle.standardOutput.write(Data("CASSINI_SPECTRO_MOTION_READY\n".utf8))
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
            let control = try motionControl(settings)
            if try XCTUnwrap(state(control),"System setting exposes a binary value") != expected { control.click() }
            let changed=NSPredicate { _,_ in self.state(control) == expected }
            XCTAssertEqual(XCTWaiter.wait(for:[XCTNSPredicateExpectation(predicate:changed,object:nil)],timeout:10),.completed,settings.debugDescription)
            let attachment=XCTAttachment(screenshot:settings.screenshot())
            attachment.name=expected ? "system-reduce-motion-on":"system-reduce-motion-off"
            attachment.lifetime = .keepAlways;add(attachment)
            settings.terminate()
            let pid=try XCTUnwrap(body["pid"] as? Int32)
            let probe = try XCTUnwrap(NSRunningApplication(processIdentifier:pid))
            let bundle=try XCTUnwrap(probe.bundleURL)
            XCTAssertEqual(bundle.pathExtension,"app","The hosted probe is a LaunchServices app")
            let reopened:NSRunningApplication = try await withCheckedThrowingContinuation { reply in
                NSWorkspace.shared.openApplication(at:bundle,configuration:NSWorkspace.OpenConfiguration()) { app,error in
                    if let error { reply.resume(throwing:error) }
                    else if let app { reply.resume(returning:app) }
                    else { reply.resume(throwing:NSError(domain:"SpectrogramMotion",code:1)) }
                }
            }
            XCTAssertEqual(reopened.processIdentifier,pid,"Reopen the measured instance")
            let foreground = NSPredicate { _,_ in NSWorkspace.shared.frontmostApplication?.processIdentifier == pid }
            XCTAssertEqual(XCTWaiter.wait(for:[XCTNSPredicateExpectation(predicate:foreground,object:nil)],timeout:5),.completed,"Probe returns to the foreground")
            let requestID = try XCTUnwrap(body["requestID"] as? String)
            let response = try JSONSerialization.data(withJSONObject:["requestID":requestID])
            // The UI runner may read project inputs without permission to
            // atomically write beside them. Its trusted orchestrator relays
            // this completion event into the probe's private handshake file.
            FileHandle.standardOutput.write(Data("CASSINI_SPECTRO_MOTION_ACK:".utf8)+response+Data([10]))
        }
    }
}
