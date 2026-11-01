// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
import Foundation
import CassiniKit
import CassiniRecording
@testable import CassiniBrowserControl

/// D52 M2/M5 through the real cassini-browser-host process and app broker:
/// negotiated source-outcomes-v1, per-source refusals, trackEnd, sources and
/// the Stop captureId fence. Shared vectors: conformance/multistream/outcomes.json.
final class D52SourceOutcomeTests: XCTestCase, @unchecked Sendable {
    private func start(_ id: String, features: [String] = ["source-outcomes-v1"]) -> [String:Any] {
        ["type":"start","version":1,"independent":true,"captureId":id,"timelineOriginMs":Int(Date().timeIntervalSince1970*1000),
         "microphone":false,"title":"Generated call","features":features,"callGeneration":1,"documentGeneration":1]
    }
    private func track(_ id: String, source: String? = nil, kind: String = "remote") -> [String:Any] {
        var packet: [String:Any] = ["type":"track","id":id,"kind":kind,"label":"Guest "+id,"sampleRate":8000,"channels":1]
        if let source { packet["sourceTrackId"] = source }
        return packet
    }
    private func audio(_ id: String, _ sequence: Int, offsetMs: Int = 0, frames: Int = 8000, value: Int16 = 200) -> [String:Any] {
        var data = Data(); for _ in 0..<frames { withUnsafeBytes(of:value.littleEndian) { data.append(contentsOf:$0) } }
        return ["type":"audio","id":id,"sequence":sequence,"offsetMs":offsetMs,"pcm":data.base64EncodedString()]
    }
    private func trackEnd(_ id: String, _ reason: String) -> [String:Any] {
        ["type":"trackEnd","id":id,"reason":reason,"droppedFrames":3,"endOffsetMs":NSNull()]
    }
    private func run(_ body: (AudioFixture, NativeAudioClient) throws -> Void) async throws {
        let fixture = try AudioFixture()
        do { try body(fixture,try fixture.client()) } catch { await fixture.finish(); throw error }
        await fixture.finish()
    }
    private func ack(_ reply: JSON, _ file: StaticString = #filePath, _ line: UInt = #line) {
        XCTAssertEqual(reply["type"]?.string,"ack","\(reply)",file:file,line:line)
    }
    private func saved(_ reply: JSON) throws -> RecordingManifest {
        try RecordingLoader.decode(Data(contentsOf:URL(fileURLWithPath:XCTUnwrap(reply["path"]?.string)).appendingPathComponent("session.json")))
    }

    func testNegotiationIsEchoedAndOlderExtensionsStayOnTheLegacyPath() async throws {
        try await run { fixture, client in
            let started = try client.request(start("negotiated"))
            XCTAssertEqual(started["features"]?.array?.compactMap(\.string),["source-outcomes-v1"])
            let legacy = try fixture.client()
            let plain = try legacy.request(start("legacy",features:[]))
            XCTAssertEqual(plain["type"]?.string,"started"); XCTAssertNil(plain["features"])
            // Without negotiation, the new packet types stay unknown session errors.
            let refused = try legacy.request(["type":"sources","discoveredSources":[["sourceTrackId":"x","kind":"remote"]]])
            XCTAssertEqual(refused["code"]?.string,"version"); XCTAssertNil(refused["scope"])
            let bad = try fixture.client()
            XCTAssertEqual(try bad.request(start("bad",features:["a","a"]))["code"]?.string,"version")
        }
    }

    func testSharedOutcomeVectorsThroughTheRealHost() async throws {
        let url = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("browser-protocol/conformance/multistream/outcomes.json")
        let cases = try XCTUnwrap(try JSONParser.parse(Data(contentsOf:url))["cases"]?.array)
        XCTAssertEqual(cases.count,5)
        let fixture = try AudioFixture()
        do {
            for (index,vector) in cases.enumerated() {
                let name = try XCTUnwrap(vector["name"]?.string), client = try fixture.client()
                let started = try client.request(start("vector-\(index)"))
                for row in vector["tracks"]?.array ?? [] {
                    ack(try client.request(track(row["id"]!.string!,source:row["sourceTrackId"]?.string)))
                }
                var sequences: [String:Int] = [:]
                for write in vector["writes"]?.array ?? [] {
                    let id = write["id"]!.string!, sequence = sequences[id, default:0]; sequences[id] = sequence + 1
                    ack(try client.request(audio(id,sequence,offsetMs:write["offsetMs"]!.int!,frames:write["frames"]!.int!,value:Int16(write["value"]!.int!))))
                }
                if let announced = vector["announcedSources"]?.array {
                    ack(try client.request(["type":"sources","discoveredSources":try announced.map { try JSONSerialization.jsonObject(with:$0.encoded(maximumBytes:4096)) }]))
                    // The ACK means the record is durable before any Stop.
                    let live = try saved(started)
                    XCTAssertEqual(Set(live.captureOutcome?.sources.map(\.sourceTrackId) ?? []),Set(announced.compactMap { $0["sourceTrackId"]?.string }),name)
                    XCTAssertEqual(live.state,"recording",name)
                }
                var stop: [String:Any] = ["type":"stop","captureId":"vector-\(index)"]
                if let summary = vector["discoveredSources"]?.array {
                    stop["discoveredSources"] = try summary.map { try JSONSerialization.jsonObject(with:$0.encoded(maximumBytes:4096)) }
                }
                let stopped = try client.request(stop)
                XCTAssertEqual(stopped["type"]?.string,"stopped",name)
                let manifest = try saved(stopped)
                let byWire = Dictionary(uniqueKeysWithValues:(vector["tracks"]?.array ?? []).map { ($0["sourceTrackId"]!.string!,$0["id"]!.string!) })
                for (source,expected) in vector["sourceExpected"]?.object ?? [] {
                    let row = try XCTUnwrap(manifest.captureOutcome?.sources.first { $0.sourceTrackId == source },"\(name): \(source)")
                    XCTAssertEqual(row.captureOutcome.rawValue,expected.string,"\(name): \(source)")
                    if let wire = byWire[source] {
                        let stored = manifest.tracks.filter { $0.sourceTrackId == source }
                        XCTAssertEqual(stored.count,1,"\(name): \(wire)")
                        XCTAssertEqual(stored.first?.captureOutcome?.rawValue,vector["expected"]?[wire]?.string,"\(name): \(wire)")
                        XCTAssertEqual(row.trackIds,stored.map(\.id),name)
                    }
                }
                let incomplete = manifest.captureOutcome!.sources.contains { $0.captureOutcome != .captured }
                XCTAssertEqual(manifest.state,incomplete ? "interrupted" : "completed",name)
                XCTAssertEqual(manifest.problemKind,incomplete ? "capture" : nil,name)
                client.end()
            }
        } catch { await fixture.finish(); throw error }
        await fixture.finish()
    }

    func testThe65thSourceIsRefusedWhileTheOther64KeepWriting() async throws {
        try await run { _, client in
            let started = try client.request(start("limit"))
            for index in 0..<64 { ack(try client.request(track("t\(index)",source:"s\(index)"))) }
            let refused = try client.request(track("t64",source:"s64"))
            XCTAssertEqual(refused["code"]?.string,"limit"); XCTAssertEqual(refused["scope"]?.string,"source"); XCTAssertEqual(refused["id"]?.string,"t64")
            for index in 0..<64 { ack(try client.request(audio("t\(index)",0))) }
            let again = try client.request(audio("t64",0))
            XCTAssertEqual(again["code"]?.string,"state"); XCTAssertEqual(again["retired"]?.bool,true)
            let stopped = try client.request(["type":"stop","captureId":"limit"])
            let manifest = try saved(stopped)
            XCTAssertEqual(manifest.tracks.count,64); XCTAssertTrue(manifest.tracks.allSatisfy { $0.frames == 8000 })
            XCTAssertEqual(manifest.captureOutcome?.sources.count,65)
            XCTAssertEqual(manifest.captureOutcome?.sources.last?.captureOutcome,.failed)
            XCTAssertEqual(manifest.state,"interrupted"); XCTAssertEqual(manifest.problemKind,"capture")
            _ = started
        }
    }

    func testRepeatedIdenticalTrackIsIdempotentAndOverlappingLiveSpansAreRefused() async throws {
        try await run { _, client in
            _ = try client.request(start("declare"))
            ack(try client.request(track("a1",source:"guest")))
            ack(try client.request(track("a1",source:"guest")))
            var conflicting = track("a1",source:"guest"); conflicting["sampleRate"] = 16000
            let conflict = try client.request(conflicting)
            XCTAssertEqual(conflict["scope"]?.string,"source"); XCTAssertEqual(conflict["code"]?.string,"source")
            // a1 was refused, so it is retired; its source is now a sticky failure.
            let overlap = try client.request(track("b1",source:"host"))
            ack(overlap)
            let second = try client.request(track("b2",source:"host"))
            XCTAssertEqual(second["scope"]?.string,"source"); XCTAssertEqual(second["id"]?.string,"b2")
            ack(try client.request(audio("b1",0)))
            let manifest = try saved(try client.request(["type":"stop","captureId":"declare"]))
            XCTAssertEqual(Set(manifest.tracks.compactMap(\.sourceTrackId)),["guest","host"])
            XCTAssertEqual(manifest.captureOutcome?.sources.first { $0.sourceTrackId == "host" }?.captureOutcome,.failed)
        }
    }

    func testCallChangedRetirementIsNotAFailureAndRetiredPacketsAreRefused() async throws {
        try await run { _, client in
            _ = try client.request(start("retire"))
            ack(try client.request(track("r1",source:"guest")))
            ack(try client.request(audio("r1",0)))
            ack(try client.request(trackEnd("r1","callChanged")))
            // A late queued packet for the retired span neither fails the source nor the capture.
            let late = try client.request(audio("r1",1,offsetMs:1000))
            XCTAssertEqual(late["code"]?.string,"state"); XCTAssertEqual(late["retired"]?.bool,true); XCTAssertEqual(late["scope"]?.string,"source")
            // The same source resumes on a fresh wire span with the same key.
            ack(try client.request(track("r2",source:"guest")))
            ack(try client.request(audio("r2",0,offsetMs:2000)))
            let manifest = try saved(try client.request(["type":"stop","captureId":"retire"]))
            let row = try XCTUnwrap(manifest.captureOutcome?.sources.first)
            XCTAssertEqual(manifest.captureOutcome?.sources.count,1)
            XCTAssertEqual(row.captureOutcome,.captured); XCTAssertEqual(row.audioMs,2000); XCTAssertEqual(row.trackIds.count,2)
            XCTAssertEqual(manifest.tracks.first?.droppedFrames,3)
            XCTAssertEqual(manifest.state,"completed"); XCTAssertNil(manifest.problemKind)
        }
    }

    func testTrackEndFailedMarksOnlyThatSource() async throws {
        try await run { _, client in
            _ = try client.request(start("failed"))
            ack(try client.request(track("x",source:"lost-guest")))
            ack(try client.request(track("y",source:"healthy")))
            ack(try client.request(audio("x",0))); ack(try client.request(audio("y",0)))
            ack(try client.request(trackEnd("x","failed")))
            ack(try client.request(audio("y",1,offsetMs:1000)))
            let manifest = try saved(try client.request(["type":"stop","captureId":"failed"]))
            XCTAssertEqual(manifest.tracks.first { $0.sourceTrackId == "lost-guest" }?.problemKind,"capture")
            XCTAssertEqual(manifest.captureOutcome?.sources.map(\.captureOutcome),[.failed,.captured])
            XCTAssertEqual(manifest.state,"interrupted"); XCTAssertEqual(manifest.problemKind,"capture")
        }
    }

    func testMalformedSourcesAndMismatchedStopAreCommandRefusalsThatKeepRecording() async throws {
        try await run { _, client in
            _ = try client.request(start("fence"))
            ack(try client.request(track("a",source:"guest")))
            let malformed = try client.request(["type":"sources","discoveredSources":[["sourceTrackId":"ok","kind":"remote"],["sourceTrackId":"","kind":"remote"]]])
            XCTAssertEqual(malformed["scope"]?.string,"command")
            let empty = try client.request(["type":"sources","discoveredSources":[]])
            XCTAssertEqual(empty["scope"]?.string,"command")
            let stale = try client.request(["type":"stop","captureId":"another-call"])
            XCTAssertEqual(stale["code"]?.string,"state"); XCTAssertEqual(stale["scope"]?.string,"command")
            ack(try client.request(audio("a",0)))
            let stopped = try client.request(["type":"stop","captureId":"fence"])
            XCTAssertEqual(stopped["type"]?.string,"stopped")
            let manifest = try saved(stopped)
            XCTAssertEqual(manifest.captureOutcome?.sources.map(\.sourceTrackId),["guest"],"The refused batch changed nothing")
            XCTAssertEqual(manifest.state,"completed")
            // A matching empty Stop after finalization ACKs without rewriting the folder.
            let before = try Data(contentsOf:URL(fileURLWithPath:stopped["path"]!.string!).appendingPathComponent("session.json"))
            XCTAssertEqual(try client.request(["type":"stop","captureId":"fence"])["type"]?.string,"stopped")
            let late = try client.request(["type":"stop","captureId":"fence","discoveredSources":[["sourceTrackId":"late","kind":"remote"]]])
            XCTAssertEqual(late["scope"]?.string,"command")
            XCTAssertEqual(try Data(contentsOf:URL(fileURLWithPath:stopped["path"]!.string!).appendingPathComponent("session.json")),before)
        }
    }
}

/// R69: a source announced while The others is off is reported but does not
/// flag the recording; selecting The others later makes it expected for good.
final class D52UnselectedSourceTests: XCTestCase {
    private func owner(_ root: URL) throws -> OwnedBrowserCapture {
        let owner = try OwnedBrowserCapture(parent:root,title:"R69",microphone:true)
        owner.enableSourceOutcomes(); return owner
    }
    func testUnselectedSourceIsNeutralUntilSelected() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("D52R69-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let quiet = try owner(root)
        try await quiet.select(me:true,others:false,atMs:0)
        try quiet.discover([.init(sourceTrackId:"unselected",kind:"remote",label:"Guest")])
        try await quiet.finish()
        let row = try XCTUnwrap(quiet.snapshot.manifest.captureOutcome?.sources.first)
        XCTAssertEqual(row.captureExpected,false); XCTAssertEqual(row.captureOutcome,.neverAudio)
        XCTAssertNotEqual(quiet.snapshot.manifest.problemKind,"capture","An unselected source never flags the recording")

        let late = try owner(root)
        try await late.select(me:true,others:false,atMs:0)
        try late.discover([.init(sourceTrackId:"later",kind:"remote",label:"Guest")])
        try await late.select(me:true,others:true,atMs:10)
        try await late.select(me:true,others:false,atMs:20)
        try await late.finish()
        let selected = try XCTUnwrap(late.snapshot.manifest.captureOutcome?.sources.first)
        XCTAssertNil(selected.captureExpected,"Selection makes the source expected permanently")
        XCTAssertEqual(late.snapshot.manifest.problemKind,"capture")
    }
}

/// D52.2 Q3 (protocol #29 writer vectors drops-after-deselection / -reselection):
/// producer drops add to the latest span that recorded the wire id.
final class D52DroppedFramesTests: XCTestCase {
    private func pcm(_ frames: Int) -> Data { Data(repeating:1,count:frames*2) }
    func testDropsStayOnTheRecordedSpanAndCountOnce() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("D52Drops-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let after = try OwnedBrowserCapture(parent:root,title:"Deselected",microphone:true)
        after.enableSourceOutcomes()
        try after.browserTrack(id:"w",label:"Guest",kind:"remote",sampleRate:48000,channels:1,sourceTrackId:"w")
        try after.browserAudio(id:"w",sequence:0,offsetMs:0,pcm:pcm(48000))
        try await after.select(me:true,others:false,atMs:1000)
        try after.trackEnd(id:"w",reason:"ended",droppedFrames:777)
        XCTAssertEqual(after.snapshot.manifest.tracks.first?.droppedFrames,777)

        let again = try OwnedBrowserCapture(parent:root,title:"Reselected",microphone:true)
        again.enableSourceOutcomes()
        try again.browserTrack(id:"w",label:"Guest",kind:"remote",sampleRate:48000,channels:1,sourceTrackId:"w")
        try again.browserAudio(id:"w",sequence:0,offsetMs:0,pcm:pcm(48000))
        try await again.select(me:true,others:false,atMs:1000)
        try await again.select(me:true,others:true,atMs:2000)
        try again.browserAudio(id:"w",sequence:1,offsetMs:2000,pcm:pcm(48000))
        try again.trackEnd(id:"w",reason:"ended",droppedFrames:777)
        let tracks = again.snapshot.manifest.tracks.filter { $0.sourceTrackId == "w" }
        XCTAssertEqual(tracks.map { $0.droppedFrames ?? 0 },[0,777])
    }
}
