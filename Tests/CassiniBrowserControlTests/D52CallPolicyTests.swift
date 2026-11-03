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
    /// Producer stamps, not the poll's clock, start the closed, fallback and return deadlines.
    func testProducerStampsDriveDeadlinesForADelayedPoll() {
        var closed = BrowserCallPolicy()
        XCTAssertEqual(closed.step(now:10,.init(page:.closed,sourceCount:1,pageObservedAt:7),source:"browser",reason:"start"),.stop(.tabClosed))
        // A stamp from the future or a non-finite one falls back to the poll's clock.
        var future = BrowserCallPolicy()
        XCTAssertNil(future.step(now:10,.init(page:.closed,sourceCount:1,pageObservedAt:50),source:"browser",reason:"start"))
        XCTAssertEqual(future.step(now:12,.init(page:.closed,sourceCount:1,pageObservedAt:50),source:"browser",reason:"start"),.stop(.tabClosed))
        var navigating = BrowserCallPolicy()
        XCTAssertEqual(navigating.step(now:10,.init(page:.navigating,sourceCount:nil,sourceCountKnown:false,pageObservedAt:7),
                                       source:"browser",reason:"start"),.fallback)
        // A page that returns after BROWSER_RETURN_GRACE, first seen late, is gone; it is not restored.
        var late = BrowserCallPolicy()
        let back = BrowserCallPolicy.Observation(page:.present,sourceCount:1,heard:true,lostAt:10)
        XCTAssertEqual(late.step(now:131,back,source:"system",reason:"lost"),.stop(.pageGone))
        var lostOnce = BrowserCallPolicy()
        let missing = BrowserCallPolicy.Observation(page:nil,rowPresent:false,sourceCount:nil,controlAlive:false,lostAt:10)
        XCTAssertEqual(lostOnce.step(now:12,missing,source:"browser",reason:"start"),.fallback)
    }
    /// A present page acknowledges each loss once: the retained stamp never restarts its deadline.
    func testARetainedLossStampIsAcknowledgedOnce() {
        var policy = BrowserCallPolicy()
        let back = BrowserCallPolicy.Observation(page:.present,sourceCount:1,heard:true,lostAt:10)
        XCTAssertEqual(policy.step(now:11,back,source:"system",reason:"lost",restoreReady:false),nil)
        XCTAssertNil(policy.step(now:200,back,source:"system",reason:"lost",restoreReady:false))
        XCTAssertEqual(policy.step(now:201,back,source:"system",reason:"lost"),.restore)
        // A new loss starts its own deadline.
        let again = BrowserCallPolicy.Observation(page:nil,rowPresent:false,sourceCount:nil,controlAlive:false,lostAt:300)
        XCTAssertNil(policy.step(now:301,again,source:"browser",reason:"restored"))
        XCTAssertEqual(policy.step(now:302,again,source:"browser",reason:"restored"),.fallback)
        XCTAssertEqual(policy.step(now:420,again,source:"system",reason:"lost"),.stop(.pageGone))
    }
    /// D52 M6: a new call generation in the tab ends the session as callEnded.
    func testACallGenerationChangeEndsTheSessionAsCallEnded() {
        XCTAssertEqual(BrowserCallPolicy.endForCallChange(started:"call-A",current:"call-B"),.callEnded)
        XCTAssertEqual(BrowserCallLifecycle.StopReason.callEnded.rawValue,"callEnded")
        XCTAssertNil(BrowserCallPolicy.endForCallChange(started:"call-A",current:"call-A"))
        XCTAssertNil(BrowserCallPolicy.endForCallChange(started:"call-A",current:nil))
        XCTAssertNil(BrowserCallPolicy.endForCallChange(started:nil,current:"call-B"))
        // Byte equality, like every other identity: canonically equal spellings are different calls.
        XCTAssertEqual(BrowserCallPolicy.endForCallChange(started:"caf\u{E9}",current:"cafe\u{301}"),.callEnded)
    }
    /// The call returns while its fallback is still waiting on the OS permission prompt: the
    /// committed source is none/lost, not system/lost. The return cancels that fallback, so
    /// restoring must not wait for the prompt (or for heard), or the Others would record nothing.
    func testAReturnRestoresAFallbackThatHasNotCommittedYet() {
        func reloaded(heard: Bool = true) -> BrowserCallPolicy {
            var policy = BrowserCallPolicy()
            XCTAssertNil(policy.step(now:0,.init(page:.present,sourceCount:1,heard:heard),source:"browser",reason:"start"))
            XCTAssertNil(policy.step(now:10,.init(page:.navigating,sourceCount:nil,sourceCountKnown:false,pageObservedAt:10),source:"browser",reason:"start"))
            XCTAssertEqual(policy.step(now:12,.init(page:.navigating,sourceCount:nil,sourceCountKnown:false),source:"browser",reason:"start"),.fallback)
            return policy
        }
        let back = BrowserCallPolicy.Observation(page:.present,sourceCount:1,heard:true)
        var policy = reloaded()
        XCTAssertNil(policy.step(now:13,back,source:"none",reason:"lost",restoreReady:false),"waits for the returning PCM")
        XCTAssertEqual(policy.step(now:13.5,back,source:"none",reason:"lost"),.restore)
        var off = reloaded()
        XCTAssertNil(off.step(now:13,back,source:"none",reason:"lost",others:false),"Others off stays off")
        var unheard = reloaded(heard:false)
        XCTAssertEqual(unheard.step(now:13,.init(page:.present,sourceCount:1),source:"none",reason:"lost"),.restore,
                       "the cancelled fallback leaves nothing to record, heard or not")
        var system = reloaded(heard:false)
        XCTAssertNil(system.step(now:13,.init(page:.present,sourceCount:1),source:"system",reason:"lost"),"a committed fallback still waits for heard")
        var dead = reloaded()
        XCTAssertEqual(dead.step(now:13,.init(page:.present,sourceCount:1,heard:true,transportAlive:false),source:"none",reason:"lost"),.fallback,
                       "a closed transport cannot restore; the fallback is asked again")
        var stopped = reloaded()
        XCTAssertNil(stopped.step(now:13,back,source:"none",reason:"stopped"),"only a loss is undone")
    }
    /// Reload under multi-stream: the navigation loss task can be cancelled by the next
    /// present/zero report before it commits. The policy still falls back two seconds after the
    /// navigating stamp, and that fallback must commit the loss first, at that stamp; otherwise
    /// the source stays alive and the fallback starts no computer sound (CI: "Navigation did
    /// not start computer-sound fallback").
    func testAFallbackAfterACancelledNavigationLossCommitsTheLoss() {
        var policy = BrowserCallPolicy()
        XCTAssertNil(policy.step(now:10,.init(page:.present,sourceCount:1,heard:true),source:"browser",reason:"start"))
        XCTAssertNil(policy.step(now:20,.init(page:.navigating,sourceCount:nil,sourceCountKnown:false,pageObservedAt:19.9),source:"browser",reason:"start"))
        // The new document is present with no sources yet; the queued loss never reached the owner.
        let rejoining = BrowserCallPolicy.Observation(page:.present,sourceCount:0,pageObservedAt:20.1)
        XCTAssertNil(policy.step(now:20.25,rejoining,source:"browser",reason:"start"))
        XCTAssertFalse(BrowserCallPolicy.commitsLoss(browserAlive:true,page:.present,count:0,multiStream:true,navigation:false,fallback:false),
                       "a present page with zero sources alone is a possible rejoin")
        XCTAssertEqual(policy.step(now:21.9,rejoining,source:"browser",reason:"start"),.fallback)
        XCTAssertTrue(BrowserCallPolicy.commitsLoss(browserAlive:true,page:.present,count:0,multiStream:true,navigation:false,fallback:true))
        XCTAssertEqual(policy.missingSince,19.9,"the loss is committed at the navigating stamp")
        // Once committed (browserAlive false) the fallback alone proceeds; a legacy peer keeps D33.
        XCTAssertFalse(BrowserCallPolicy.commitsLoss(browserAlive:false,page:.present,count:0,multiStream:true,navigation:false,fallback:true))
        XCTAssertTrue(BrowserCallPolicy.commitsLoss(browserAlive:true,page:.present,count:0,multiStream:false,navigation:false,fallback:false))
        XCTAssertTrue(BrowserCallPolicy.commitsLoss(browserAlive:false,page:.navigating,count:nil,multiStream:true,navigation:true,fallback:false))
    }
    /// D57 (R78.1): the resume ask waits until the status no longer lists a session for the tab,
    /// and waiting does not use up the once-per-loss-and-connection ask.
    func testTheResumeAskWaitsForTheTabSessionToLeaveTheStatus() {
        var policy = BrowserCallPolicy(resumeCapture:true,callGeneration:"call-A",heard:true)
        var row = BrowserCallPolicy.Observation(page:.present,sourceCount:1,heard:true,transportAlive:false,callGeneration:"call-A",controlConnection:"c1")
        row.sessionListed = true
        XCTAssertFalse(policy.steps(now:1,row,source:"system",reason:"lost").contains(.askResume))
        XCTAssertFalse(policy.steps(now:2,row,source:"system",reason:"lost").contains(.askResume))
        row.sessionListed = false
        XCTAssertTrue(policy.steps(now:3,row,source:"system",reason:"lost").contains(.askResume))
        XCTAssertFalse(policy.steps(now:4,row,source:"system",reason:"lost").contains(.askResume),"still once per loss and connection")
    }
}
