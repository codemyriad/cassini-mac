// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
import CassiniKit
@testable import CassiniBrowserControl

final class CallSignalTests: XCTestCase {
    private let a = UUID(), b = UUID()
    private func row(_ generation: String = "call-A", document: String = "doc-A", state: String = "active", remote: String = "mixed", tab: Int = 2, site: String = "Synthetic call") -> BrowserCallSignal {
        .init(tabID:tab,url:"https://call.example/",document:document,remoteAudio:remote,state:state,
              reason:state == "active" ? "activeCall" : state == "inactive" ? "callEnded" : "unverified",site:site,generation:generation)
    }
    private func peer(_ rows: [BrowserCallSignal], seq: Int = 0, replacement: Bool = false, profile: String = "profile-A") -> SignalCallPolicy.Peer {
        .init(id:replacement ? b : a,order:replacement ? 2 : 1,snapshot:.init(instance:profile,sequence:seq,tabs:rows))
    }
    private func running() throws -> (SignalCallPolicy,UUID) {
        var policy = SignalCallPolicy(); policy.update([peer([row()])],now:0); policy.advance(now:0,enabled:true)
        let token = try XCTUnwrap(policy.reserve()); policy.didStart(token); return (policy,token)
    }
    func testOptInMixedAndPositiveProofRequired() {
        for r in [row(state:"unknown"),row(state:"inactive"),row(remote:"separated"),row(remote:"unknown")] {
            var p = SignalCallPolicy(); p.update([peer([r])],now:0); p.advance(now:0,enabled:true)
            XCTAssertNil(p.reserve())
        }
        var p = SignalCallPolicy(); p.update([peer([row()])],now:0); p.advance(now:0,enabled:false)
        XCTAssertNil(p.reserve()); p.advance(now:1,enabled:true); XCTAssertNotNil(p.reserve()); XCTAssertNil(p.reserve())
    }
    func testDifferentGenerationEndStartsExactGraceWithoutExtendingIt() throws {
        for document in ["doc-A","doc-B"] {
            var (p,token) = try running()
            p.update([peer([row("call-B",document:document,state:"inactive")],seq:1)],now:10)
            XCTAssertNil(p.retiring)
            p.update([peer([row("call-B",document:document,state:"inactive")],seq:2)],now:100)
            p.advance(now:129.999,enabled:true); XCTAssertTrue(p.mayOpen(token)); XCTAssertNil(p.retiring)
            p.advance(now:130,enabled:true); XCTAssertEqual(p.retiring,.pageGone)
        }
    }
    func testStopBeforeAdmissionSuppressesAcrossReconnectWithoutAnOwner() {
        var p = SignalCallPolicy(); p.update([peer([row()])],now:0); p.suppress()
        p.advance(now:1,enabled:true); XCTAssertNil(p.reserve())
        p.update([peer([row()],replacement:true)],now:2); p.advance(now:2,enabled:true); XCTAssertNil(p.reserve())
        p.update([peer([row("call-B")],seq:1,replacement:true)],now:3); p.advance(now:3,enabled:true); XCTAssertNotNil(p.reserve())
    }
    func testStopAlsoSuppressesUnadmittedFactsWhileRecordingOrRetiring() throws {
        for retiring in [false,true] {
            var (p,token) = try running()
            if retiring { p.update([peer([row(state:"inactive")],seq:1)],now:1) }
            p.update([peer([row("call-B")],seq:2)],now:2)
            p.suppress(); p.release(token,failed:false)
            p.update([peer([row("call-B")],replacement:true)],now:3); p.advance(now:3,enabled:true)
            XCTAssertNil(p.reserve())
            p.update([peer([row("call-C")],seq:1,replacement:true)],now:4); p.advance(now:4,enabled:true)
            XCTAssertNotNil(p.reserve())
        }
    }
    func testOverlapSharesOwnerAndLastPositiveEndStopsImmediately() throws {
        var (p,token) = try running()
        p.update([peer([row(),row("call-B",tab:3)],seq:1)],now:1); p.advance(now:1,enabled:true)
        XCTAssertEqual(p.calls.count,2); XCTAssertNil(p.reserve())
        p.update([peer([row(state:"inactive"),row("call-B",tab:3)],seq:2)],now:2)
        XCTAssertNil(p.retiring); XCTAssertTrue(p.mayOpen(token))
        p.update([peer([row(state:"inactive"),row("call-B",state:"inactive",tab:3)],seq:3)],now:3)
        XCTAssertEqual(p.retiring,.callEnded); XCTAssertFalse(p.mayOpen(token))
    }
    func testReplacementPeerReconcilesAndOldPeerCannotEndOrReviveIt() throws {
        var (p,token) = try running()
        p.update([],now:1); p.update([peer([row()],replacement:true)],now:50)
        p.advance(now:122,enabled:true); XCTAssertTrue(p.mayOpen(token)); XCTAssertNil(p.reserve())
        p.update([peer([row(state:"inactive")],seq:99),peer([row()],replacement:true)],now:123)
        XCTAssertNil(p.retiring)
        p.update([peer([row()],seq:100)],now:124); p.advance(now:243.999,enabled:true); XCTAssertNil(p.retiring)
        p.advance(now:244,enabled:true); XCTAssertEqual(p.retiring,.pageGone)
    }
    func testPendingUnknownEndAndStopCannotOpenInputs() throws {
        for terminal in ["unknown","inactive","stop"] {
            var p = SignalCallPolicy(); p.update([peer([row()])],now:0); p.advance(now:0,enabled:true)
            let token = try XCTUnwrap(p.reserve()); XCTAssertTrue(p.mayOpen(token))
            if terminal == "stop" { p.suppress() } else { p.update([peer([row(state:terminal)],seq:1)],now:1) }
            XCTAssertFalse(p.mayOpen(token))
        }
    }
    func testPendingRouteProvenanceCannotRebindToAnotherSiteDuringPermissionWork() throws {
        var p = SignalCallPolicy()
        p.update([peer([row(site:"Alpha"),row("call-B",tab:3,site:"Beta")])],now:0); p.advance(now:0,enabled:true)
        XCTAssertEqual(p.site,"Alpha"); let token = try XCTUnwrap(p.reserve())
        p.update([peer([row(state:"inactive",site:"Alpha"),row("call-B",tab:3,site:"Beta")],seq:1)],now:1)
        XCTAssertFalse(p.mayOpen(token)); XCTAssertEqual(p.retiring,.callEnded)
        p.release(token,failed:false); p.advance(now:2,enabled:true)
        XCTAssertEqual(p.site,"Beta"); XCTAssertNotNil(p.reserve())
    }
    func testDiskAndInputFailureStopCannotAutomaticallyLoopTheSameCalls() throws {
        for reason in [CaptureEndReason.disk,.error] {
            var (p,token) = try running(); p.suppress(reason:reason)
            XCTAssertEqual(p.retiring,reason)
            p.release(token,failed:false); p.advance(now:1,enabled:true)
            XCTAssertNil(p.reserve())
            p.update([peer([row("call-B")],seq:1)],now:2); p.advance(now:2,enabled:true)
            XCTAssertNotNil(p.reserve())
        }
    }
    func testPendingLossHasNoRunningGraceAndFreshProofCanReserveAfterCancellation() throws {
        for transition in ["unknown","separated","disconnect"] {
            var p = SignalCallPolicy(); p.update([peer([row()])],now:0); p.advance(now:0,enabled:true)
            let token = try XCTUnwrap(p.reserve())
            if transition == "disconnect" { p.update([],now:1) }
            else { p.update([peer([row(state:transition == "unknown" ? "unknown" : "active",remote:transition == "separated" ? "separated" : "mixed")],seq:1)],now:1) }
            XCTAssertEqual(p.retiring,.pageGone); XCTAssertFalse(p.mayOpen(token))
            p.release(token,failed:false)
            p.update([peer([row()],seq:2,replacement:true)],now:2); p.advance(now:2,enabled:true)
            XCTAssertNotNil(p.reserve(),"Evidence loss is not a manual-Stop suppression")
        }
    }
    func testRouteStaysSystemAndBrowserOwnedCallCannotJoinSignalOwner() throws {
        var (p,token) = try running()
        p.update([peer([row(remote:"separated")],seq:1)],now:1); p.advance(now:121,enabled:true)
        XCTAssertTrue(p.mayOpen(token)); XCTAssertTrue(p.owns(instance:"profile-A",tab:2,generation:"call-A"))
        var other = SignalCallPolicy(); other.update([peer([row()])],now:0)
        other.advance(now:0,enabled:true,blocked:{ _,_ in true }); XCTAssertNil(other.reserve())
    }
    func testOpaqueGenerationDocumentAndProfileIdentitiesCompareExactUTF8() throws {
        let composed = "caf\u{e9}", decomposed = "cafe\u{301}"
        XCTAssertEqual(composed,decomposed,"Swift text equality normalizes; control identities must not")
        for field in ["document","generation","profile"] {
            var p = SignalCallPolicy()
            let original = row(field == "generation" ? composed : "call-A",document:field == "document" ? composed : "doc-A")
            p.update([peer([original],profile:field == "profile" ? composed : "profile-A")],now:0); p.advance(now:0,enabled:true)
            let token = try XCTUnwrap(p.reserve()); p.didStart(token)
            let next = row(field == "generation" ? decomposed : "call-A",document:field == "document" ? decomposed : "doc-A")
            p.update([peer([next],seq:1,profile:field == "profile" ? decomposed : "profile-A")],now:1)
            if field == "profile" {
                p.advance(now:1,enabled:true); XCTAssertEqual(p.calls.count,2,"Distinct profiles may share one system owner")
            } else { XCTAssertEqual(p.retiring,.callEnded,"A distinct opaque generation must fence its predecessor") }
        }
    }
    func testParserRunsSharedValidAndInvalidSignalVectors() throws {
        let root = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let corpus = try JSONParser.parse(Data(contentsOf:root.appendingPathComponent("browser-protocol/conformance/control/call-signals-vectors.json")))
        for vector in corpus["valid"]?.array ?? [] where vector["message"]?["type"]?.string == "callSignals" {
            XCTAssertNoThrow(try BrowserCallSignalSnapshot.read(try XCTUnwrap(vector["message"])),vector["name"]?.string ?? "")
        }
        for vector in corpus["passiveMediaNegatives"]?.array ?? [] {
            let snapshot = try BrowserCallSignalSnapshot.read(try XCTUnwrap(vector["signal"]))
            var p = SignalCallPolicy()
            p.update([.init(id:a,order:1,snapshot:snapshot)],now:0); p.advance(now:0,enabled:true)
            XCTAssertNil(p.reserve(),vector["name"]?.string ?? "Passive media")
        }
        for vector in corpus["invalid"]?.array ?? [] where vector["message"]?["type"]?.string == "callSignals" {
            XCTAssertThrowsError(try BrowserCallSignalSnapshot.read(try XCTUnwrap(vector["message"])),vector["name"]?.string ?? "")
        }
    }
}
