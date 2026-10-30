// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import XCTest
@testable import CassiniBrowserControl

final class SharedCallLifecycleTests: XCTestCase {
    func testEveryLiteralD33VectorAgainstTheProductionPolicy() throws {
        let root = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let file = root.appendingPathComponent("browser-protocol/conformance/control/call-lifecycle-vectors.json")
        let vectors = try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:file)) as? [String:Any])
        XCTAssertEqual(vectors["constants"] as? [String:Int],["CALL_END_GRACE":2,"BROWSER_RETURN_GRACE":120])
        let cases = try XCTUnwrap(vectors["cases"] as? [[String:Any]])
        XCTAssertEqual(cases.count,15)
        for vector in cases {
            var policy = BrowserCallLifecycle(), system = false
            let others = vector["others"] as? Bool ?? true
            for step in try XCTUnwrap(vector["steps"] as? [[String:Any]]) {
                let time = Double(try XCTUnwrap(step["atMs"] as? Int))/1000
                let action = policy.step(now:time,page:(step["pageState"] as? String).flatMap(BrowserCallLifecycle.Page.init),
                    sourceCount:try XCTUnwrap(step["sourceCount"] as? Int),sameTab:step["sameTab"] as? Bool ?? true,
                    usingSystem:system,others:others,restoreReady:step["restoreReady"] as? Bool ?? true)
                var actual: [String] = []
                if let action {
                    switch action {
                    case .fallback: actual = ["fallback"]; system = true
                    case .restore: actual = ["restore"]; system = false
                    case .stop(let reason): actual = ["stop:"+reason.rawValue]
                    }
                }
                XCTAssertEqual(actual,try XCTUnwrap(step["expect"] as? [String]),"\(vector["name"] ?? "?") at \(time)")
            }
        }
    }
    func testSourceChangesStayUncommittedUntilTheDeviceOwnerSucceeds() {
        var policy = BrowserCallLifecycle()
        XCTAssertNil(policy.step(now:0,page:.navigating,sourceCount:0,usingSystem:false,others:true))
        XCTAssertEqual(policy.step(now:2,page:.navigating,sourceCount:0,usingSystem:false,others:true),.fallback)
        // A failed device start does not silently turn this into system capture.
        XCTAssertEqual(policy.step(now:3,page:.navigating,sourceCount:0,usingSystem:false,others:true),.fallback)
        XCTAssertNil(policy.step(now:4,page:.navigating,sourceCount:0,usingSystem:true,others:true))
        XCTAssertNil(policy.step(now:5,page:.present,sourceCount:1,transportAlive:false,usingSystem:true,others:true))
        XCTAssertEqual(policy.step(now:6,page:.present,sourceCount:1,usingSystem:true,others:true),.restore)
        // Staging a restore may fail; the working system source remains selected.
        XCTAssertEqual(policy.step(now:7,page:.present,sourceCount:1,usingSystem:true,others:true),.restore)
        XCTAssertNil(policy.step(now:8,page:.present,sourceCount:1,usingSystem:false,others:true))
    }
}
