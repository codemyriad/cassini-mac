// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
import Foundation
import CassiniKit
@testable import CassiniBrowserControl

/// D52 M3: the literal shared multi-stream lifecycle vectors through the Mac
/// policy. The runner plays the owner: each requested action is committed.
final class D52CallPolicyTests: XCTestCase {
    func testSharedMultiStreamLifecycleVectors() throws {
        let url = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("browser-protocol/conformance/multistream/lifecycle.json")
        let file = try JSONParser.parse(Data(contentsOf:url))
        XCTAssertEqual(file["constants"]?["OTHERS_GONE_GRACE"]?.double,BrowserCallPolicy.othersGoneGrace*1000)
        XCTAssertEqual(file["constants"]?["TAB_CLOSED_GRACE"]?.double,BrowserCallPolicy.tabClosedGrace*1000)
        XCTAssertEqual(file["constants"]?["BROWSER_RETURN_GRACE"]?.double,BrowserCallPolicy.browserReturnGrace*1000)
        let cases = try XCTUnwrap(file["cases"]?.array)
        XCTAssertEqual(cases.count,26)
        for vector in cases {
            let name = vector["name"]!.string!
            var policy = BrowserCallPolicy(resumeCapture:vector["resumeCapture"]?.bool ?? false,callGeneration:vector["callGeneration"]?.string)
            var source = vector["source"]?.string ?? "browser", reason = vector["sourceReason"]?.string ?? "start"
            for step in vector["steps"]!.array! {
                let page: BrowserCallLifecycle.Page? = step["pageState"]?.string.map { BrowserCallLifecycle.Page(rawValue:$0) } ?? .present
                let observation = BrowserCallPolicy.Observation(page:page,rowPresent:step["rowPresent"]?.bool ?? true,sourceCount:step["sourceCount"]?.int,
                    sourceCountKnown:step["sourceCountKnown"]?.bool ?? (step["sourceCount"]?.int != nil),heard:step["heard"]?.bool ?? false,
                    controlAlive:step["controlAlive"]?.bool ?? true,pcmLive:step["pcmLive"]?.bool ?? false,
                    transportAlive:step["transportAlive"]?.bool ?? true,callGeneration:step["callGeneration"]?.string,
                    controlConnection:String(step["controlConnection"]?.int ?? 0))
                // resumeRefused changes nothing: no retry until a new controlConnection.
                let at = step["atMs"]!.double!
                var actual: [String] = []
                for action in policy.steps(now:at/1000,observation,source:source,reason:reason) {
                    switch action {
                    case .fallback: actual.append("fallback"); source = "system"; reason = "lost"
                    case .restore: actual.append("restore"); source = "browser"; reason = "restored"
                    case .callConnected: actual.append("switch:browser:callConnected"); source = "browser"; reason = "callConnected"
                    case .askResume: actual.append("askResume")
                    case .stop(let why): actual.append("stop:"+why.rawValue)
                    }
                }
                XCTAssertEqual(actual,step["expect"]!.array!.compactMap(\.string),"\(name) at \(at)")
            }
        }
    }
    func testTheNativeMicrophoneIsNotBrowserEvidenceAndTheOthersOffNeverFallsBack() {
        var policy = BrowserCallPolicy()
        let absent = BrowserCallPolicy.Observation(page:nil,rowPresent:false,sourceCount:nil,controlAlive:false,pcmLive:false)
        XCTAssertNil(policy.step(now:0,absent,source:"browser",reason:"start",others:false))
        XCTAssertNil(policy.step(now:5,absent,source:"browser",reason:"start",others:false))
        XCTAssertEqual(policy.step(now:6,absent,source:"browser",reason:"start"),.fallback)
        // An explicit system choice (reason start/user) is never switched by a call.
        var chosen = BrowserCallPolicy()
        let present = BrowserCallPolicy.Observation(page:.present,sourceCount:1,heard:true)
        XCTAssertNil(chosen.step(now:0,present,source:"system",reason:"user"))
        XCTAssertNil(chosen.step(now:1,present,source:"system",reason:"start"))
    }
}
