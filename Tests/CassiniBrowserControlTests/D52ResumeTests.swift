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
            XCTAssertEqual(capture.snapshot.manifest.events?.first { $0.type == "othersSource" }?.reason,"missing")
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
