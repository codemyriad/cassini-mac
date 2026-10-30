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
    func testDelayedObserverUsesProducerDeadlinesBeforeReturnOrFallback() {
        var closed = BrowserCallLifecycle()
        XCTAssertEqual(closed.step(now:105,page:.closed,sourceCount:1,usingSystem:false,others:true,pageObservedAt:100),.stop(.tabClosed))
        var navigation = BrowserCallLifecycle()
        XCTAssertEqual(navigation.step(now:225,page:.navigating,sourceCount:0,usingSystem:false,others:true,pageObservedAt:100),.stop(.pageGone))
        var returned = BrowserCallLifecycle()
        XCTAssertEqual(returned.step(now:220,page:.present,sourceCount:1,usingSystem:true,others:true,lostAt:100),.stop(.pageGone))
        var fallback = BrowserCallLifecycle()
        XCTAssertEqual(fallback.step(now:102,page:.navigating,sourceCount:0,usingSystem:false,others:true,pageObservedAt:100),.fallback)
    }
    func testAcknowledgedProducerLossDoesNotRestartGraceAfterAReturnOrFailedRestore() {
        var policy = BrowserCallLifecycle()
        XCTAssertEqual(policy.step(now:105,page:.present,sourceCount:1,usingSystem:true,others:true,lostAt:100),.restore)
        XCTAssertEqual(policy.step(now:230,page:.present,sourceCount:1,usingSystem:true,others:true,lostAt:100),.restore)
        XCTAssertNil(policy.step(now:231,page:.present,sourceCount:0,usingSystem:true,others:true,lostAt:100))
        XCTAssertEqual(policy.step(now:233,page:.present,sourceCount:0,usingSystem:true,others:true,lostAt:100),.stop(.callEnded))
    }
    func testANewNavigationAfterAnAcknowledgedLossUsesItsOwnObservedTime() {
        var policy = BrowserCallLifecycle()
        XCTAssertEqual(policy.step(now:105,page:.present,sourceCount:1,usingSystem:true,others:true,lostAt:100),.restore)
        XCTAssertNil(policy.step(now:200,page:.navigating,sourceCount:0,usingSystem:true,others:true,pageObservedAt:199,lostAt:100))
        XCTAssertNil(policy.step(now:318,page:.navigating,sourceCount:0,usingSystem:true,others:true,pageObservedAt:199,lostAt:100))
        XCTAssertEqual(policy.step(now:319,page:.present,sourceCount:1,usingSystem:true,others:true,lostAt:100),.stop(.pageGone))
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
