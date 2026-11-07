// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
import Foundation
import CassiniKit
import CassiniRecording
@testable import CassiniBrowserControl

final class DOMProvenanceTests: XCTestCase, @unchecked Sendable {
    func testDiscoverySnapshotSurvivesReplacementReselectionAndRealStop() async throws {
        let fixture = try AudioFixture()
        do {
            let client = try fixture.client()
            _ = try client.request(start("dom"))
            let owner = try XCTUnwrap(fixture.broker.activeCaptures.first)
            ack(try client.request(["type":"sources","discoveredSources":[source("person","Hypatia","dom"),source("silent","Ibn Sina","dom")]]))
            ack(try client.request(track("a",source:"person",label:"Changed later",provenance:"browser")))
            ack(try client.request(audio("a",0,0)))
            ack(try client.request(["type":"trackEnd","id":"a","reason":"ended","droppedFrames":0,"endOffsetMs":1000]))
            ack(try client.request(track("b",source:"person",label:"Changed again",provenance:"browser")))
            ack(try client.request(audio("b",0,1000)))
            try await owner.select(me:true,others:false,atMs:2000)
            try await owner.select(me:false,others:true,atMs:2500)
            ack(try client.request(audio("b",1,2500)))
            let stopped = try client.request(["type":"stop","captureId":"dom","discoveredSources":[source("person","Newest label","browser"),source("silent","Newest silent label","browser")]])
            XCTAssertEqual(stopped["type"]?.string,"stopped")
            let manifest = try RecordingLoader.load(directory:owner.snapshot.directory)
            XCTAssertGreaterThanOrEqual(manifest.tracks.count,3)
            for track in manifest.tracks { XCTAssertEqual(track.label,"Hypatia"); XCTAssertEqual(track.labelSource,"dom") }
            XCTAssertEqual(manifest.captureOutcome?.sources.first { $0.sourceTrackId == "person" }?.labelSource,"dom")
            let silent = try XCTUnwrap(manifest.captureOutcome?.sources.first { $0.sourceTrackId == "silent" })
            XCTAssertEqual(silent.label,"Ibn Sina"); XCTAssertEqual(silent.labelSource,"dom"); XCTAssertEqual(silent.captureOutcome,.failed)
            let portable = try JSONSerialization.jsonObject(with:Data(contentsOf:owner.snapshot.directory.appendingPathComponent("meeting.json"))) as? [String:Any]
            let savedRecord = (portable?["recordingDetails"] as? [String:Any])?["captureRecord"] as? [String:Any]
            XCTAssertEqual((savedRecord?["sources"] as? [[String:Any]])?.first?["labelSource"] as? String,"dom")
            let fresh = try CaptureRecordWriter.record(manifest)
            let sources = try XCTUnwrap(fresh["sources"] as? [[String:Any]])
            XCTAssertEqual(sources.first { $0["sourceTrackId"] as? String == "silent" }?["labelSource"] as? String,"dom")
            for track in try XCTUnwrap(fresh["tracks"] as? [[String:Any]]) { XCTAssertEqual(track["labelSource"] as? String,"dom") }
            var stored = fresh
            var rows = sources; rows[0]["futureProvenanceDetail"] = "retained"; stored["sources"] = rows
            let merged = try XCTUnwrap(CaptureRecordWriter.merge(stored,fresh))
            XCTAssertEqual((merged["sources"] as? [[String:Any]])?.first?["futureProvenanceDetail"] as? String,"retained")
        } catch { await fixture.finish(); throw error }
        await fixture.finish()
    }

    func testInvalidProvenanceIsRefusedAtomicallyAndLegacyMetadataDefaultsToBrowser() async throws {
        let fixture = try AudioFixture()
        do {
            let client = try fixture.client(); _ = try client.request(start("validation"))
            for (index,bad) in ["user","device","recovered","",17,true,[],[:]] .enumerated() {
                let key = "invalid-\(index)"
                let invalid = track(key,source:key,label:"Synthetic guest",provenance:bad)
                let refused = try client.request(invalid)
                XCTAssertEqual(refused["type"]?.string,"error"); XCTAssertEqual(refused["code"]?.string,"source")
                for type in ["sources","stop"] {
                    let refused = try client.request(["type":type,"captureId":"validation","discoveredSources":[source("partial-\(index)","Valid","dom"),source(key,"Invalid",bad)]])
                    XCTAssertEqual(refused["type"]?.string,"error"); XCTAssertEqual(refused["scope"]?.string,"command","\(refused)")
                }
            }
            for (index,value) in [nil,NSNull(),"browser","dom"].enumerated() {
                let key = "valid-\(index)"
                ack(try client.request(track(key,source:key,label:"Synthetic guest",provenance:value)))
                ack(try client.request(audio(key,0,index*1000)))
            }
            let stopped = try client.request(["type":"stop","captureId":"validation"])
            XCTAssertEqual(stopped["type"]?.string,"stopped")
            let manifest = try RecordingLoader.load(directory:URL(fileURLWithPath:XCTUnwrap(stopped["path"]?.string)))
            XCTAssertEqual(manifest.tracks.map(\.labelSource),["browser","browser","browser","dom"])
            XCTAssertEqual(manifest.captureOutcome?.sources.map(\.labelSource),["browser","browser","browser","dom"])
            XCTAssertEqual(manifest.captureOutcome?.sources.count,4,"No invalid/partial source registration")
        } catch { await fixture.finish(); throw error }
        await fixture.finish()
    }

    func testRestoredAndLazyReselectedSpansRetainDOMProvenance() async throws {
        let fixture = try AudioFixture()
        do {
            let origin = 1_793_500_000_000
            let owner = try OwnedBrowserCapture(parent:fixture.root.appendingPathComponent("Library"),title:"Synthetic stand-in",microphone:false,browser:false)
            let writer = owner.nativeWriter(side:.others)
            try writer.addTrack(id:"system",label:"Others",kind:"system",sampleRate:8000,channels:1)
            try writer.appendNative(id:"system",pcm:Data(repeating:0,count:1600),offsetMs:0)
            try fixture.broker.ownNative(owner,timelineOriginMs:origin)
            let id = try XCTUnwrap(fixture.broker.standInIdentity(owner)).captureID
            fixture.broker.expectResume(owner,callGeneration:"call-A")
            let client = try fixture.client()
            let resumed = try client.request(["type":"resume","version":1,"independent":true,"captureId":id,"timelineOriginMs":origin,"callGeneration":"call-A","features":["source-outcomes-v1","resume-capture-v1"]])
            XCTAssertEqual(resumed["type"]?.string,"started")
            ack(try client.request(track("returning",source:"person",label:"Hypatia",provenance:"dom")))
            ack(try client.request(track("quiet",source:"quiet",label:"Ibn Sina",provenance:"dom")))
            ack(try client.request(audio("returning",0,1000)))
            try await owner.restoreBrowser(atMs:2000)
            ack(try client.request(audio("quiet",0,2100))) // lazy span
            try await owner.select(me:true,others:false,atMs:3500)
            try await owner.select(me:false,others:true,atMs:4000)
            ack(try client.request(audio("returning",1,4100)))
            XCTAssertEqual(try client.request(["type":"stop","captureId":id])["type"]?.string,"stopped")
            let manifest = try RecordingLoader.load(directory:owner.snapshot.directory)
            let remotes = manifest.tracks.filter { $0.kind == "remote" }
            XCTAssertGreaterThanOrEqual(remotes.count,4)
            XCTAssertTrue(remotes.allSatisfy { $0.labelSource == "dom" })
            XCTAssertEqual(manifest.tracks.first { $0.kind == "system" }?.labelSource,"device")
            for source in manifest.captureOutcome?.sources.filter({ $0.kind == "remote" }) ?? [] { XCTAssertEqual(source.labelSource,"dom") }
        } catch { await fixture.finish(); throw error }
        await fixture.finish()
    }
    private func start(_ id: String) -> [String:Any] {
        ["type":"start","version":1,"independent":true,"captureId":id,"timelineOriginMs":1_793_500_000_000,"microphone":false,"title":"Synthetic English call","features":["source-outcomes-v1"]]
    }
    private func source(_ id: String, _ label: String, _ provenance: Any) -> [String:Any] {
        ["sourceTrackId":id,"kind":"remote","label":label,"labelSource":provenance,"failed":id == "silent"]
    }
    private func track(_ id: String, source: String, label: String, provenance: Any?) -> [String:Any] {
        var value: [String:Any] = ["type":"track","id":id,"sourceTrackId":source,"kind":"remote","label":label,"sampleRate":8000,"channels":1]
        value["labelSource"] = provenance; return value
    }
    private func audio(_ id: String, _ sequence: Int, _ offset: Int) -> [String:Any] {
        ["type":"audio","id":id,"sequence":sequence,"offsetMs":offset,"pcm":Data(repeating:1,count:16000).base64EncodedString()]
    }
    private func ack(_ value: JSON, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(value["type"]?.string,"ack","\(value)",file:file,line:line)
    }
}
