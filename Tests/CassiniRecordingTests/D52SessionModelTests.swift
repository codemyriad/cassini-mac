// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
import Foundation
import CassiniKit
@testable import CassiniRecording

/// D52 wave 1 session groundwork: D49 callConnected, per-track outcome fields,
/// admitted-frame accounting and a failed span that leaves the others recording.
final class D52SessionModelTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("D52Session-"+UUID().uuidString)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at:root) }

    private func pcm(frames: Int, channels: Int = 1, value: Int16 = 200) -> Data {
        var data = Data(); data.reserveCapacity(frames*channels*2)
        for _ in 0..<(frames*channels) { withUnsafeBytes(of:value.littleEndian) { data.append(contentsOf:$0) } }
        return data
    }
    private func stored(_ session: RecordingSession) throws -> RecordingManifest {
        try RecordingLoader.decode(Data(contentsOf:session.directory.appendingPathComponent("session.json")))
    }
    private func standIn(_ reason: String) throws -> RecordingSession {
        let session = try RecordingSession(parent:root,title:"Stand-in",source:"macos")
        try session.transition(starting:[.init(id:"mic",label:"Mic",kind:"microphone",sampleRate:48000,channels:1),
                                         .init(id:"system",label:"System",kind:"system",sampleRate:48000,channels:1)],
                               events:[.init(atMs:0,type:"selection",reason:"start",me:true,others:true),
                                       .init(atMs:0,type:"othersSource",source:"system",reason:reason)])
        return session
    }
    private let remote = RecordingSource(id:"remote-1",label:"Guest",kind:"remote",sampleRate:48000,channels:1,sourceTrackId:"receiver-a")

    func testCallConnectedTakesOverOnlyTheInitialMissingStandIn() throws {
        let session = try standIn("missing")
        try session.transition(starting:[remote],ending:["system"],events:[.init(atMs:1000,type:"othersSource",source:"browser",reason:"callConnected")])
        let events = try XCTUnwrap(try stored(session).events)
        XCTAssertEqual(events.last?.reason,"callConnected")
        let state = CaptureSourceState(events:events,atMs:1000)
        XCTAssertEqual(state.source,"browser"); XCTAssertEqual(state.reason,"callConnected"); XCTAssertFalse(state.fallback)
        XCTAssertEqual(CaptureSourceState(events:events,atMs:999).reason,"missing")
        try session.finish()
    }
    func testCallConnectedIsRefusedAfterALostOrStartedSystemSource() throws {
        for reason in ["lost","start"] {
            let session = try standIn(reason)
            XCTAssertThrowsError(try session.transition(starting:[remote],ending:["system"],
                events:[.init(atMs:1000,type:"othersSource",source:"browser",reason:"callConnected")]),reason)
            XCTAssertEqual(try stored(session).events?.count,2,reason)
            try session.finish()
        }
        // restored keeps its existing D33 meaning after lost.
        let lost = try standIn("lost")
        try lost.transition(starting:[remote],ending:["system"],events:[.init(atMs:1000,type:"othersSource",source:"browser",reason:"restored")])
        try lost.finish()
    }
    func testCallConnectedNeedsTheNewBrowserSpanAndBrowserSource() throws {
        let session = try standIn("missing")
        XCTAssertThrowsError(try session.transition(ending:["system"],events:[.init(atMs:1000,type:"othersSource",source:"browser",reason:"callConnected")]))
        XCTAssertFalse(CaptureEvent(atMs:1,type:"othersSource",source:"system",reason:"callConnected").isKnownValid)
        try session.finish()
    }
    func testReaderDropsACallConnectedWithoutAMissingStandIn() throws {
        let raw = try JSONParser.parse(Data("""
        [{"atMs":0,"type":"selection","reason":"start","me":true,"others":true},
         {"atMs":0,"type":"othersSource","source":"system","reason":"lost"},
         {"atMs":5,"type":"othersSource","source":"browser","reason":"callConnected"},
         {"atMs":6,"type":"othersSource","source":"system","reason":"missing"},
         {"atMs":7,"type":"othersSource","source":"browser","reason":"callConnected"}]
        """.utf8))
        let events = CaptureEvent.read(raw)
        XCTAssertEqual(events.map(\.atMs),[0,0,6,7])
        let off = try JSONParser.parse(Data("""
        [{"atMs":0,"type":"selection","reason":"start","me":true,"others":false},
         {"atMs":0,"type":"othersSource","source":"system","reason":"missing"},
         {"atMs":5,"type":"othersSource","source":"browser","reason":"callConnected"}]
        """.utf8))
        XCTAssertEqual(CaptureEvent.read(off).count,2,"The others switched off cannot be taken over")
    }

    func testReceivedFramesCountAdmittedPCMButNotGapPadding() throws {
        let session = try RecordingSession(parent:root,title:"Sparse",source:"chromium")
        try session.transition(starting:[remote])
        try session.append(id:"remote-1",pcm:pcm(frames:4800,value:0),offsetMs:0)
        try session.append(id:"remote-1",pcm:pcm(frames:4800),offsetMs:2000)
        try session.finish()
        let track = try XCTUnwrap(try stored(session).tracks.first)
        XCTAssertEqual(track.frames,96000+4800)
        XCTAssertEqual(track.receivedFrames,9600,"Zeros count as received; the 1.9 s of padding does not")
    }

    func testAFailedSpanEndsAloneWhileTheOthersKeepRecording() throws {
        let session = try RecordingSession(parent:root,title:"Two",source:"chromium")
        try session.transition(starting:[remote,.init(id:"remote-2",label:"Host",kind:"remote",sampleRate:48000,channels:1,sourceTrackId:"receiver-b")])
        try session.append(id:"remote-1",pcm:pcm(frames:480),offsetMs:0)
        try session.append(id:"remote-2",pcm:pcm(frames:480),offsetMs:0)
        try session.failTrack(id:"remote-1",problemKind:"io")
        XCTAssertThrowsError(try session.append(id:"remote-1",pcm:pcm(frames:480),offsetMs:10))
        try session.append(id:"remote-2",pcm:pcm(frames:480),offsetMs:10)
        var manifest = try stored(session)
        XCTAssertEqual(manifest.state,"recording")
        XCTAssertEqual(manifest.tracks[0].problemKind,"io"); XCTAssertEqual(manifest.tracks[0].ended,true)
        XCTAssertEqual(manifest.tracks[0].endOffsetMs,10)
        XCTAssertNil(manifest.tracks[1].problemKind)
        XCTAssertThrowsError(try session.failTrack(id:"remote-2",problemKind:"other"))
        try session.finish(problem:"Some audio couldn't be recorded.",kind:"capture")
        manifest = try stored(session)
        XCTAssertEqual(manifest.problemKind,"io","I/O loss takes precedence over a capture problem")
        XCTAssertEqual(manifest.tracks[1].frames,960)
    }

    func testOutcomeThresholdsMatchTheSharedMinimum() throws {
        let url = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("browser-protocol/conformance/multistream/outcomes.json")
        let minimum = try XCTUnwrap(try JSONParser.parse(Data(contentsOf:url))["minimumAudioMs"]?.double)
        XCTAssertEqual(minimum,1000)
        XCTAssertEqual(CaptureOutcome(failed:false,audioMs:0),.neverAudio)
        XCTAssertEqual(CaptureOutcome(failed:false,audioMs:minimum.nextDown),.lowAudio)
        XCTAssertEqual(CaptureOutcome(failed:false,audioMs:minimum),.captured)
        XCTAssertEqual(CaptureOutcome(failed:true,audioMs:60000),.failed)
    }

    func testCaptureOutcomeRoundTripsAndMalformedRowsAreIgnored() throws {
        let session = try RecordingSession(parent:root,title:"Ledger",source:"chromium")
        try session.transition(starting:[remote])
        session.setCaptureOutcome(.init(sources:[
            .init(sourceTrackId:"receiver-a",kind:"remote",label:"Guest",captureOutcome:.lowAudio,audioMs:100,trackIds:["remote-1"]),
            .init(sourceTrackId:"never",kind:"remote",label:nil,captureOutcome:.failed,audioMs:0,trackIds:[],captureExpected:false)],
            unreportedSourceCount:2),tracks:["remote-1":.lowAudio])
        try session.append(id:"remote-1",pcm:pcm(frames:4800),offsetMs:0)
        try session.finish()
        let manifest = try stored(session)
        XCTAssertEqual(manifest.captureOutcome?.sources.map(\.sourceTrackId),["receiver-a","never"])
        XCTAssertEqual(manifest.captureOutcome?.sources[1].expected,false)
        XCTAssertEqual(manifest.captureOutcome?.sources[0].expected,true)
        XCTAssertEqual(manifest.captureOutcome?.unreportedSourceCount,2)
        XCTAssertEqual(manifest.tracks[0].captureOutcome,.lowAudio)

        let raw = """
        {"version":1,"id":"\(UUID().uuidString)","createdAt":"2026-11-01T10:00:00Z","title":"t","source":"chromium","state":"completed","tracks":[
          {"id":"a","label":"A","kind":"remote","file":"a.wav","sampleRate":48000,"channels":1,"frames":0,"captureOutcome":"bogus","problemKind":"disk","receivedFrames":-1}],
         "captureOutcome":{"sources":[{"sourceTrackId":"ok","kind":"remote","captureOutcome":"captured","audioMs":1200,"trackIds":["a"],"future":1},
           {"sourceTrackId":"","kind":"remote","captureOutcome":"captured","audioMs":1,"trackIds":[]},
           {"sourceTrackId":"bad","kind":"remote","captureOutcome":"partial","audioMs":1,"trackIds":[]}],"unreportedSourceCount":-3}}
        """
        let loaded = try RecordingLoader.decode(Data(raw.utf8))
        XCTAssertEqual(loaded.captureOutcome?.sources.map(\.sourceTrackId),["ok"])
        XCTAssertNil(loaded.captureOutcome?.unreportedSourceCount)
        XCTAssertNil(loaded.tracks[0].captureOutcome); XCTAssertNil(loaded.tracks[0].problemKind); XCTAssertNil(loaded.tracks[0].receivedFrames)
    }
}
