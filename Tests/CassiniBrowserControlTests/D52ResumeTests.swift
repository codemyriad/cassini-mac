// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
import Foundation
import CassiniKit
import CassiniLibrary
import CassiniRecording
@testable import CassiniBrowserControl

/// D52.1 R67 host side of resume-capture-v1 through the real cassini-browser-host
/// and app broker, against a native system/missing stand-in. Schedules follow
/// conformance/control/resume-capture-vectors.json where they apply to a host.
final class D52ResumeTests: XCTestCase, @unchecked Sendable {
    private let origin = 1793500000000
    private func resume(_ id: String, generation: String = "call-A", origin: Int? = nil) -> [String:Any] {
        ["type":"resume","version":1,"independent":true,"captureId":id,"timelineOriginMs":origin ?? self.origin,"callGeneration":generation,
         "features":["source-outcomes-v1","resume-capture-v1"]]
    }
    private func standIn(_ fixture: AudioFixture, changed: @escaping @Sendable (OwnedCaptureSnapshot) -> Void = { _ in }) throws -> (OwnedBrowserCapture,String) {
        let capture = try OwnedBrowserCapture(parent:fixture.root.appendingPathComponent("Library"),title:"Stand-in",microphone:true,browser:false,changed:changed)
        // The stand-in exists once computer sound actually arrives (D33): its first buffer
        // publishes system/missing.
        let system = capture.nativeWriter(side:.others)
        try system.addTrack(id:"output",label:"Others",kind:"system",sampleRate:8000,channels:1)
        try system.appendNative(id:"output",pcm:Data(repeating:0,count:1600),offsetMs:0)
        try fixture.broker.ownNative(capture,timelineOriginMs:origin)
        let identity = try XCTUnwrap(fixture.broker.standInIdentity(capture))
        XCTAssertEqual(identity.timelineOriginMs,origin)
        return (capture,identity.captureID)
    }
    private func folders(_ fixture: AudioFixture) -> Int {
        ((try? FileManager.default.contentsOfDirectory(atPath:fixture.root.appendingPathComponent("Library").path)) ?? []).filter { $0.hasPrefix("Recording-") }.count
    }
    private func run(_ body: (AudioFixture) async throws -> Void) async throws {
        let fixture = try AudioFixture()
        do { try await body(fixture) } catch { await fixture.finish(); throw error }
        await fixture.finish()
    }

    func testAcceptedResumeJoinsTheStandInAndCommitsCallConnected() async throws {
        try await run { fixture in
            let (capture,id) = try standIn(fixture)
            XCTAssertEqual(capture.snapshot.manifest.events?.last { $0.type == "othersSource" }?.reason,"missing")
            fixture.broker.expectResume(capture,callGeneration:"call-A")
            let client = try fixture.client()
            let started = try client.request(resume(id))
            XCTAssertEqual(started["type"]?.string,"started"); XCTAssertEqual(started["resumed"]?.bool,true)
            XCTAssertEqual(started["captureId"]?.string,id); XCTAssertEqual(started["timelineOriginMs"]?.int,origin)
            XCTAssertEqual(started["callGeneration"]?.string,"call-A")
            XCTAssertEqual(Set(started["features"]?.array?.compactMap(\.string) ?? []),["source-outcomes-v1","resume-capture-v1"])
            XCTAssertEqual(started["path"]?.string,capture.snapshot.directory.path)
            XCTAssertEqual(folders(fixture),1,"No new folder")
            XCTAssertEqual(try client.request(["type":"track","id":"r1","kind":"remote","label":"Guest","sampleRate":8000,"channels":1,"sourceTrackId":"guest"])["type"]?.string,"ack")
            XCTAssertEqual(try client.request(["type":"audio","id":"r1","sequence":0,"offsetMs":0,"pcm":Data(repeating:1,count:16000).base64EncodedString()])["type"]?.string,"ack")
            XCTAssertTrue(capture.snapshot.restoreReady)
            try await capture.restoreBrowser(atMs:6000)
            XCTAssertEqual(capture.snapshot.manifest.events?.last { $0.type == "othersSource" }?.reason,"callConnected")
            XCTAssertEqual(capture.snapshot.manifest.events?.filter { $0.type == "selection" }.count,1,"Selection unchanged")
            let stopped = try client.request(["type":"stop","captureId":id])
            XCTAssertEqual(stopped["type"]?.string,"stopped")
            XCTAssertEqual(capture.snapshot.phase,.saved)
        }
    }
    func testUnarmedStaleOrMismatchedResumesAreRefusedWithoutSideEffects() async throws {
        try await run { fixture in
            let (capture,id) = try standIn(fixture)
            let before = capture.snapshot.manifest.events
            // Not armed by the app: refused.
            XCTAssertEqual(try fixture.client().request(resume(id))["code"]?.string,"state")
            fixture.broker.expectResume(capture,callGeneration:"call-B")
            // stale-call-A: the app selected B; a late A resume cannot bind.
            XCTAssertEqual(try fixture.client().request(resume(id,generation:"call-A"))["code"]?.string,"state")
            XCTAssertEqual(try fixture.client().request(resume(id,generation:"call-B",origin:origin+1))["code"]?.string,"state")
            XCTAssertEqual(try fixture.client().request(resume("native-unknown",generation:"call-B"))["code"]?.string,"state")
            var noFeature = resume(id,generation:"call-B"); noFeature["features"] = ["source-outcomes-v1"]
            XCTAssertEqual(try fixture.client().request(noFeature)["code"]?.string,"version")
            XCTAssertEqual(capture.snapshot.manifest.events,before); XCTAssertFalse(capture.snapshot.transportAlive)
            XCTAssertEqual(folders(fixture),1)
            // Still armed for B: the correct resume is accepted afterwards.
            XCTAssertEqual(try fixture.client().request(resume(id,generation:"call-B"))["resumed"]?.bool,true)
        }
    }
    func testStopFencesAResumeAndAFreshRecordStillWorks() async throws {
        try await run { fixture in
            let (capture,id) = try standIn(fixture)
            fixture.broker.expectResume(capture,callGeneration:"call-A")
            // Stop claims the end intent before its drain: a resume arriving now is refused.
            capture.requestEnd(.user)
            XCTAssertEqual(try fixture.client().request(resume(id))["code"]?.string,"state")
            try await fixture.broker.finish(capture)
            XCTAssertEqual(try fixture.client().request(resume(id))["code"]?.string,"state","A saved target never resumes")
            let fresh = try fixture.client()
            let started = try fresh.request(["type":"start","version":1,"independent":true,"captureId":"fresh","timelineOriginMs":origin,"microphone":false,"title":"Fresh"])
            XCTAssertEqual(started["type"]?.string,"started"); XCTAssertNil(started["resumed"])
            XCTAssertNotEqual(started["path"]?.string,capture.snapshot.directory.path)
            XCTAssertEqual(folders(fixture),2)
        }
    }
    func testResumedTransportEOFKeepsTheNativeRecording() async throws {
        try await run { fixture in
            // E1: wait for the owner's published transport loss, not a timer.
            let lost = expectation(description:"transport loss published"); lost.assertForOverFulfill = false
            let joined = Flag()
            let (capture,id) = try standIn(fixture) { snapshot in if joined.value && !snapshot.transportAlive { lost.fulfill() } }
            fixture.broker.expectResume(capture,callGeneration:"call-A")
            let client = try fixture.client()
            XCTAssertEqual(try client.request(resume(id))["resumed"]?.bool,true)
            joined.set(); client.end()
            await fulfillment(of:[lost],timeout:5)
            XCTAssertEqual(capture.snapshot.phase,.recording)
            fixture.broker.expectResume(capture,callGeneration:"call-A")
            XCTAssertEqual(try fixture.client().request(resume(id))["resumed"]?.bool,true,"A later resume may join again")
        }
    }
    /// #103 review 1: once the call has taken over, the recording is a browser recording: a
    /// later navigation with the transport still open is a browser loss and falls back to
    /// computer sound. Before take-over the stand-in stays a plain native recording.
    func testATakenOverStandInFallsBackToSystemSoundOnNavigation() async throws {
        try await run { fixture in
            let (capture,id) = try standIn(fixture)
            XCTAssertTrue(BrowserCallPolicy.standInPending(source:"macos",keyed:true,events:capture.snapshot.manifest.events ?? []))
            fixture.broker.expectResume(capture,callGeneration:"call-A")
            let client = try fixture.client()
            XCTAssertEqual(try client.request(resume(id))["resumed"]?.bool,true)
            XCTAssertEqual(try client.request(["type":"track","id":"r1","kind":"remote","label":"Guest","sampleRate":8000,"channels":1,"sourceTrackId":"guest"])["type"]?.string,"ack")
            XCTAssertEqual(try client.request(["type":"audio","id":"r1","sequence":0,"offsetMs":0,"pcm":Data(repeating:1,count:16000).base64EncodedString()])["type"]?.string,"ack")
            try await capture.restoreBrowser(atMs:6000)
            let events = capture.snapshot.manifest.events ?? []
            XCTAssertFalse(BrowserCallPolicy.standInPending(source:"macos",keyed:true,events:events),"take-over committed")
            // The resumed page navigates; its transport stays connected.
            XCTAssertTrue(BrowserCallPolicy.commitsLoss(browserAlive:true,page:.navigating,count:nil,multiStream:true,navigation:true,fallback:false))
            try capture.browserLost(atMs:7000,transportAlive:true)
            XCTAssertFalse(capture.snapshot.browserAlive); XCTAssertTrue(capture.snapshot.transportAlive)
            try await capture.requestSystemFallback()
            let system = capture.nativeWriter(side:.others)
            try system.addTrack(id:"fallback",label:"Others",kind:"system",sampleRate:8000,channels:1)
            try system.appendNative(id:"fallback",pcm:Data(repeating:2,count:1600),offsetMs:7100)
            let last = capture.snapshot.manifest.events?.last { $0.type == "othersSource" }
            XCTAssertEqual(last?.source,"system"); XCTAssertEqual(last?.reason,"lost")
            XCTAssertEqual(capture.snapshot.phase,.recording)
            _ = try client.request(["type":"stop","captureId":id])
        }
    }
    /// #103 review 3: while a resume is pending, the stand-in is not yet the call's
    /// recording, so a call change never ends it; a refused resume leaves it recording.
    func testACallChangeDuringAPendingResumeKeepsTheNativeRecording() async throws {
        try await run { fixture in
            let (capture,id) = try standIn(fixture)
            fixture.broker.expectResume(capture,callGeneration:"call-A")
            // The tab moves on to call B before the resume commits; the app re-arms for B.
            XCTAssertEqual(BrowserCallPolicy.endForCallChange(started:"call-A",current:"call-B"),.callEnded)
            XCTAssertTrue(BrowserCallPolicy.standInPending(source:"macos",keyed:true,events:capture.snapshot.manifest.events ?? []),
                          "call-change termination does not apply before take-over")
            fixture.broker.expectResume(capture,callGeneration:"call-B")
            XCTAssertEqual(try fixture.client().request(resume(id,generation:"call-A"))["code"]?.string,"state")
            XCTAssertEqual(capture.snapshot.phase,.recording)
            XCTAssertEqual(capture.snapshot.manifest.events?.last { $0.type == "othersSource" }?.reason,"missing")
            XCTAssertNil(capture.snapshot.manifest.events?.last { $0.type == "end" })
            XCTAssertEqual(folders(fixture),1)
        }
    }
    /// #103 review 2: an active stand-in's identity is retained, so after a browser restart the
    /// recovered call's interrupted capture marks its tab attempted and auto-record never
    /// starts a second recording of it.
    func testAResumedStandInStaysRetainedAcrossABrowserRestart() async throws {
        try await run { fixture in
            let (capture,id) = try standIn(fixture)
            XCTAssertTrue(fixture.broker.retainedCaptureIDs.contains(id))
            fixture.broker.expectResume(capture,callGeneration:"call-A")
            XCTAssertEqual(try fixture.client().request(resume(id))["resumed"]?.bool,true)
            func recovered(retaining ids: [String]) throws -> [BrowserControlRequest] {
                var registry = BrowserControlRegistry(instanceAlive:{ _ in true })
                registry.setRetainedCaptureIDs(ids)
                let peer = UUID()
                try registry.connect(.init(id:peer,role:.control,browser:"Chrome",browserInstance:.init(pid:4242,startSeconds:7)))
                func send(_ value: [String:Any]) throws { try registry.receive(JSONSerialization.data(withJSONObject:value),from:peer) }
                try send(["type":"hello","version":1,"capabilities":["independent-sessions-v1","page-state-v1","multi-stream-v1","resume-capture-v1"]])
                try send(["type":"meetings","meetings":[["tabId":2,"title":"Call","url":"https://meet.example/a","sourceCount":1,"heard":true,
                                                           "pageState":"present","callGeneration":"call-A"]]])
                let session: [String:Any] = ["recording":false,"tabId":2,"captureId":id,"path":NSNull(),"message":"Interrupted","tracks":1]
                try send(["type":"status","recording":false,"tabId":NSNull(),"path":NSNull(),"message":"Ready","sessions":[],"interrupted":[session]])
                return registry.automaticStarts(microphone:true)
            }
            XCTAssertTrue(try recovered(retaining:fixture.broker.retainedCaptureIDs).isEmpty,"the recovered call is already being recorded")
            XCTAssertEqual(try recovered(retaining:[]).count,1,"without the stand-in identity the call would be recorded twice")
            XCTAssertEqual(capture.snapshot.phase,.recording)
        }
    }
    /// #103 delta review 1: when control disappears before the take-over, the collection's
    /// D33 branch runs (multiStream false). A pending stand-in never steps it, so no pageGone
    /// ends the native recording however long control stays away.
    func testAControlLossBeforeTakeOverNeverEndsTheStandIn() async throws {
        try await run { fixture in
            let (capture,id) = try standIn(fixture)
            fixture.broker.expectResume(capture,callGeneration:"call-A")
            XCTAssertEqual(try fixture.client().request(resume(id))["resumed"]?.bool,true)
            var policy = BrowserCallPolicy(), lifecycle = BrowserCallLifecycle(), legacySteps = 0
            let gone = BrowserCallPolicy.Observation(page:nil,rowPresent:false,sourceCount:nil,controlAlive:false)
            for second in stride(from:0.0,through:300,by:0.25) {
                let pending = BrowserCallPolicy.standInPending(source:"macos",keyed:true,events:capture.snapshot.manifest.events ?? [])
                let action = BrowserCallPolicy.decide(pending:pending,multiStream:false,policy:&policy,now:second,gone,
                                                      source:"system",reason:"missing",others:true,restoreReady:false) {
                    legacySteps += 1
                    return lifecycle.step(now:second,page:nil,sourceCount:0,transportAlive:false,usingSystem:true,others:true,restoreReady:false)
                }
                XCTAssertNil(action,"at \(second) s")
            }
            XCTAssertEqual(legacySteps,0,"the D33 lifecycle never runs for a pending stand-in")
            XCTAssertEqual(capture.snapshot.phase,.recording)
            // Unprotected, the same D33 lifecycle ends the recording as pageGone.
            var unprotected = BrowserCallLifecycle(), ended: BrowserCallLifecycle.Action?
            for second in stride(from:0.0,through:300,by:0.25) {
                let step = unprotected.step(now:second,page:nil,sourceCount:0,transportAlive:false,usingSystem:true,others:true,restoreReady:false)
                if case .stop? = step { ended = step; break }
            }
            XCTAssertEqual(ended,.stop(.pageGone))
        }
    }
    /// #103 delta review 2: an accepted resume whose call shows no sources past the 30 s grace
    /// must still take over once sources and PCM return: the recording's policy is not stepped
    /// (so never stopped) before take-over, and it works normally afterwards.
    func testAnExpiredGraceBeforeTakeOverStillCommitsCallConnected() async throws {
        try await run { fixture in
            let (capture,id) = try standIn(fixture)
            fixture.broker.expectResume(capture,callGeneration:"call-A")
            let client = try fixture.client()
            XCTAssertEqual(try client.request(resume(id))["resumed"]?.bool,true)
            var policy = BrowserCallPolicy()
            func poll(_ second: Double, count: Int) -> BrowserCallLifecycle.Action? {
                let pending = BrowserCallPolicy.standInPending(source:"macos",keyed:true,events:capture.snapshot.manifest.events ?? [])
                let committed = CaptureSourceState(events:capture.snapshot.manifest.events ?? [],atMs:.infinity)
                return BrowserCallPolicy.decide(pending:pending,multiStream:true,policy:&policy,now:second,
                    .init(page:.present,sourceCount:count,heard:true),source:committed.source,reason:committed.reason,others:true,
                    restoreReady:capture.snapshot.restoreReady) { XCTFail("no legacy lifecycle under multi-stream"); return nil }
            }
            XCTAssertNil(poll(0,count:1))
            for second in stride(from:1.0,through:45,by:0.25) { XCTAssertNil(poll(second,count:0),"no stop before take-over at \(second) s") }
            // Sources and PCM return on the resumed transport.
            XCTAssertEqual(try client.request(["type":"track","id":"r1","kind":"remote","label":"Guest","sampleRate":8000,"channels":1,"sourceTrackId":"guest"])["type"]?.string,"ack")
            XCTAssertEqual(try client.request(["type":"audio","id":"r1","sequence":0,"offsetMs":46000,"pcm":Data(repeating:1,count:16000).base64EncodedString()])["type"]?.string,"ack")
            XCTAssertTrue(capture.snapshot.restoreReady)
            XCTAssertEqual(poll(46,count:1),.restore)
            try await capture.restoreBrowser(atMs:46100)
            XCTAssertEqual(capture.snapshot.manifest.events?.last { $0.type == "othersSource" }?.reason,"callConnected")
            // Now a browser recording: its own policy runs, starting fresh.
            XCTAssertNil(poll(47,count:1))
            XCTAssertNil(poll(48,count:0))
            XCTAssertEqual(poll(78,count:0),.stop(.callEnded),"the call's own 30 s grace applies after take-over")
            // Unprotected, stepping the same policy through the wait leaves it stopped for good.
            var consumed = BrowserCallPolicy()
            _ = consumed.step(now:0,.init(page:.present,sourceCount:1,heard:true),source:"system",reason:"missing")
            var terminal: BrowserCallPolicy.Action?
            for second in stride(from:1.0,through:45,by:0.25) {
                let step = consumed.step(now:second,.init(page:.present,sourceCount:0,heard:true),source:"system",reason:"missing")
                if case .stop? = step { terminal = step; break }
            }
            XCTAssertEqual(terminal,.stop(.callEnded))
            XCTAssertNil(consumed.step(now:46,.init(page:.present,sourceCount:1,heard:true),source:"system",reason:"missing"),"no callConnected after a terminal stop")
            _ = try client.request(["type":"stop","captureId":id])
        }
    }
    func testSharedResumeSeamOwnership() throws {
        let url = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("browser-protocol/conformance/control/resume-capture-vectors.json")
        let file = try JSONParser.parse(Data(contentsOf:url))
        // D52.4: the D49 seam and the seam after a lost audio transport place the same way.
        for name in ["seam","lostSeam"] {
            let seam = try XCTUnwrap(file[name],name)
            let ownership = try XCTUnwrap(OthersOwnership(events:CaptureEvent.read(seam["events"])))
            for track in seam["tracks"]!.array! {
                let id = track["id"]!.string!
                let owned = ownership.owned(kind:track["kind"]!.string!,startMs:track["startMs"]!.double!,endMs:track["endMs"]!.double!)
                let expected = seam["expectedWindows"]![id]!.array!.map { [$0.array![0].double!,$0.array![1].double!] }
                XCTAssertEqual(owned.map { [$0.0,$0.1] },expected,"\(name) \(id)")
            }
        }
    }
    /// D52.4 `targets`: which current othersSource a resume may attach to, and the seam it writes.
    func testSharedResumeTargets() throws {
        let url = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("browser-protocol/conformance/control/resume-capture-vectors.json")
        let targets = try XCTUnwrap(try JSONParser.parse(Data(contentsOf:url))["targets"])
        let eligible = try XCTUnwrap(targets["eligible"]?.array), ineligible = try XCTUnwrap(targets["ineligible"]?.array)
        XCTAssertFalse(eligible.isEmpty); XCTAssertFalse(ineligible.isEmpty)
        for row in eligible {
            XCTAssertEqual(OwnedBrowserCapture.resumeSeamReason(source:row["source"]?.string,reason:row["reason"]?.string),row["seamReason"]?.string,"\(row)")
        }
        for row in ineligible { XCTAssertNil(OwnedBrowserCapture.resumeSeamReason(source:row["source"]?.string,reason:row["reason"]?.string),"\(row)") }
    }
    /// D52.4 through the real host: a browser recording whose audio transport closed falls
    /// back to system/lost, keeps its identity, and a resume joins it with browser/restored.
    func testALostBrowserRecordingResumesOntoItsFallbackAsRestored() async throws {
        try await run { fixture in
            let origin = Int(Date().timeIntervalSince1970*1000)
            let first = try fixture.client()
            let started = try first.request(["type":"start","version":1,"independent":true,"captureId":"lost-call","timelineOriginMs":origin,"microphone":false,
                                             "title":"Call","features":["source-outcomes-v1"],"callGeneration":"call-A","documentGeneration":1])
            XCTAssertEqual(started["type"]?.string,"started")
            let capture = try XCTUnwrap(fixture.broker.activeCaptures.first { $0.snapshot.directory.path == started["path"]?.string })
            XCTAssertEqual(try first.request(["type":"track","id":"a","kind":"remote","label":"Guest","sampleRate":8000,"channels":1,"sourceTrackId":"guest"])["type"]?.string,"ack")
            XCTAssertEqual(try first.request(["type":"audio","id":"a","sequence":0,"offsetMs":0,"pcm":Data(repeating:1,count:1600).base64EncodedString()])["type"]?.string,"ack")
            first.end()
            let deadline = Date().addingTimeInterval(5)
            while capture.snapshot.transportAlive || fixture.broker.standInIdentity(capture) == nil {
                guard Date() < deadline else { return XCTFail("the transport loss was never observed") }
                try await Task.sleep(nanoseconds:10_000_000)
            }
            // The identity stays taken: a fresh Start reusing it creates nothing.
            XCTAssertEqual(try fixture.client().request(["type":"start","version":1,"independent":true,"captureId":"lost-call","timelineOriginMs":origin,
                                                          "microphone":false,"title":"Again"])["type"]?.string,"error")
            XCTAssertEqual(folders(fixture),1)
            // none/lost (the fallback has not started yet) is not a target.
            fixture.broker.expectResume(capture,callGeneration:"call-A")
            XCTAssertEqual(try fixture.client().request(resume("lost-call",origin:origin))["type"]?.string,"error")
            // Fall back to computer sound, as the policy does at once.
            try await capture.requestSystemFallback()
            let stage = StagedNativeWriter()
            try stage.addTrack(id:"system",label:"System",kind:"system",sampleRate:8000,channels:1)
            try stage.appendNative(id:"system",pcm:Data(repeating:2,count:1600),offsetMs:1000)
            try await capture.activateNative(stage,side:.others,allowed:{ true })
            let fallback = capture.snapshot.manifest.events?.last { $0.type == "othersSource" }
            XCTAssertEqual(fallback?.source,"system"); XCTAssertEqual(fallback?.reason,"lost")
            fixture.broker.expectResume(capture,callGeneration:"call-A")
            let client = try fixture.client()
            let resumed = try client.request(resume("lost-call",origin:origin))
            XCTAssertEqual(resumed["resumed"]?.bool,true); XCTAssertEqual(resumed["path"]?.string,capture.snapshot.directory.path)
            let declared = try client.request(["type":"track","id":"r1","kind":"remote","label":"Guest","sampleRate":8000,"channels":1,"sourceTrackId":"guest"]); XCTAssertEqual(declared["type"]?.string,"ack","\(declared)")
            XCTAssertEqual(try client.request(["type":"audio","id":"r1","sequence":0,"offsetMs":5000,"pcm":Data(repeating:1,count:16000).base64EncodedString()])["type"]?.string,"ack")
            XCTAssertTrue(capture.snapshot.restoreReady)
            try await capture.restoreBrowser(atMs:6000)
            let seam = capture.snapshot.manifest.events?.last { $0.type == "othersSource" }
            XCTAssertEqual(seam?.source,"browser"); XCTAssertEqual(seam?.reason,"restored")
            XCTAssertEqual(folders(fixture),1,"No new folder")
            XCTAssertEqual(try client.request(["type":"stop","captureId":"lost-call"])["type"]?.string,"stopped")
        }
    }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock(); private var flag = false
    var value: Bool { lock.withLock { flag } }
    func set() { lock.withLock { flag = true } }
}
