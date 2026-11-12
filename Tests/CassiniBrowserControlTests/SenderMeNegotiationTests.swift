// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
import Foundation
import CassiniRecording
import CassiniKit
@testable import CassiniBrowserControl

final class SenderMeNegotiationTests: XCTestCase, @unchecked Sendable {
    func testVerifiedAdmissionPreservesBothNativeStartOwnershipModes() throws {
        for captureLocal in [false,true] {
            let store=BrowserAutomaticAdmissionStore()
            let request=BrowserControlRequest(id:"manual",key:.init(peer:UUID(),tabID:2),action:.start,data:Data())
            try store.issue(request,browser:nil,generation:"call-A",document:"hook-A",microphone:true,verifiedConfigured:false,deadline:nil)
            let original=BrowserAudioStart(captureID:"capture",timelineOriginMs:1000,microphone:true,captureLocal:captureLocal,callGeneration:"call-A",documentGeneration:"hook-A",requestID:.string("manual"))
            let accepted=try store.authorize(original,browser:nil)
            XCTAssertEqual(accepted.captureLocal,captureLocal)
        }
    }

    func testOnlyHelloSenderMeCapabilityEnablesStartAndResumeLocalCapture() throws {
        for capability in [nil,"sender-me-v1-extra","sender-me-v1"] {
            for resume in [false,true] {
                var state=BrowserControlRegistry();let peer=UUID()
                try state.connect(.init(id:peer,role:.control,browser:"Chromium"))
                var capabilities=["independent-sessions-v1","multi-stream-v1","resume-capture-v1"]
                if let capability { capabilities.append(capability) }
                for packet: [String:Any] in [
                    ["type":"hello","version":1,"capabilities":capabilities],
                    ["type":"meetings","meetings":[["tabId":2,"title":"Synthetic call","url":"https://meet.example/call","sourceCount":1,"callGeneration":"call-A"]]],
                    ["type":"status","sessions":[],"recording":false,"tabId":NSNull(),"path":NSNull(),"message":"Ready"]
                ] { try state.receive(JSONSerialization.data(withJSONObject:packet),from:peer) }
                let key=BrowserMeetingKey(peer:peer,tabID:2)
                let request=try resume ? state.resume(key,captureID:"kept",timelineOriginMs:1000,lostAtMs:0).0 : state.start(key,microphone:true)
                let command=try JSONParser.parse(request.data)
                XCTAssertEqual(command["captureLocal"]?.bool,capability == "sender-me-v1")
                XCTAssertEqual(state.snapshots.first?.supportsSenderMe,capability == "sender-me-v1")
            }
        }
    }

    func testNativeStartFlagSelectsImmutableOwnerModeAndLegacyMicrophone() async throws {
        for flag in [nil,false,true] {
            let admitted=expectation(description:"Native start reached capture factory")
            let expectedLocal=flag == true
            let fixture=try AudioFixture(created:{ owner,info in
                XCTAssertEqual(info.captureLocal,expectedLocal,"Verified admission must retain the native flag")
                XCTAssertEqual(owner.nativeMe,!expectedLocal)
                admitted.fulfill()
            })
            
            do {
            let client=try fixture.client()
            var packet:[String:Any]=["type":"start","version":1,"independent":true,"captureId":UUID().uuidString,"timelineOriginMs":Int(Date().timeIntervalSince1970*1000),"microphone":true,"title":"Negotiated synthetic call"]
            if let flag { packet["captureLocal"]=flag }
            XCTAssertEqual(try client.request(packet)["type"]?.string,"started")
            await fulfillment(of:[admitted],timeout:5)
            let owner=try XCTUnwrap(fixture.broker.activeCaptures.first)
            XCTAssertEqual(owner.nativeMe,!expectedLocal)
            if expectedLocal {
                XCTAssertFalse(owner.snapshot.manifest.tracks.contains { $0.kind == "microphone" })
            }
            _=try client.request(["type":"stop"])
            } catch { await fixture.finish(); throw error }
            await fixture.finish()
        }
    }

    func testInvalidNativeCaptureLocalIsRefusedBeforeAnyFactorySideEffect() async throws {
        for flag:Any in ["true",1,NSNull()] {
            let fixture=try AudioFixture(beforeCreate:{ XCTFail("Invalid flag must not create outputs or inputs") })
            
            do {
            let client=try fixture.client()
            let reply=try client.request(["type":"start","version":1,"independent":true,"captureId":"invalid","timelineOriginMs":1000,"captureLocal":flag])
            XCTAssertEqual(reply["code"]?.string,"source")
            XCTAssertTrue(fixture.broker.activeCaptures.isEmpty)
            } catch { await fixture.finish(); throw error }
            await fixture.finish()
        }
    }

    func testMeOnlyBrowserLossStopsWithCaptureProblemEvenBeforeFirstPCM() async throws {
        for (observedLoss,hasPCM) in [(false,false),(false,true),(true,false),(true,true)] {
            let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
            defer { try? FileManager.default.removeItem(at:root) }
            let owner=try OwnedBrowserCapture(parent:root,title:"Browser Me loss",microphone:true,captureLocal:true,managedBrowser:true)
            owner.enableSourceOutcomes()
            try await owner.select(me:true,others:false,atMs:0)
            if hasPCM {
                try owner.browserTrack(id:"me",label:"Me",kind:"local",sampleRate:8000,channels:1)
                try owner.browserAudio(id:"me",sequence:0,offsetMs:0,pcm:Data(repeating:0x12,count:1600))
            }
            XCTAssertFalse(owner.needsBrowserMeLossStop)
            if observedLoss {
                try owner.browserLost(atMs:100,transportAlive:false)
                XCTAssertTrue(owner.needsBrowserMeLossStop,"The app's production stop predicate must fire with no possible source")
            }
            // Otherwise verified admission reports pageGone before a queued
            // observeBrowserLoss reaches the owner. It must still save a problem.
            try await owner.finish(reason:.pageGone,atMs:100)
            XCTAssertEqual(owner.snapshot.phase,.saved)
            XCTAssertEqual(owner.snapshot.manifest.problemKind,"capture")
            XCTAssertEqual(try RecordingLoader.load(directory:owner.snapshot.directory).problemKind,"capture")
            XCTAssertNotNil(owner.snapshot.manifest.problem)
            XCTAssertFalse(owner.snapshot.manifest.tracks.contains { ["microphone","system"].contains($0.kind) })
            XCTAssertEqual(owner.snapshot.manifest.tracks.reduce(0) { $0+$1.frames },hasPCM ? 800 : 0)
        }
    }
}
