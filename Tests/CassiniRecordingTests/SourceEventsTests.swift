// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
import Foundation
import Darwin
import CassiniKit
import CassiniLibrary
@testable import CassiniRecording

final class SourceEventsTests: XCTestCase {
    func testProducerUUIDCannotOverwriteAnExistingFolder() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let id = UUID(), first = try RecordingSession(parent:root,title:"Keep",source:"macos",id:id)
        let file = first.directory.appendingPathComponent("session.json"), before = try Data(contentsOf:file)
        XCTAssertThrowsError(try RecordingSession(parent:root,title:"Replace",source:"macos",id:id))
        XCTAssertEqual(try Data(contentsOf:file),before)
        try first.finish()
    }
    func fixture(_ name: String) throws -> Data {
        try Data(contentsOf:XCTUnwrap(Bundle.module.url(forResource:name,withExtension:nil,subdirectory:"SessionEvents")))
    }
    func testSharedFallbackTimelineAndUnknownEventFields() throws {
        let raw = try JSONParser.parse(fixture("session.json"))
        let manifest = try RecordingLoader.decode(fixture("session.json"))
        let expected = try JSONParser.parse(fixture("expected.json"))
        XCTAssertEqual(manifest.events?.count,5)
        for row in try XCTUnwrap(expected["states"]?.array) {
            let state = CaptureSourceState(events:manifest.events ?? [],atMs:try XCTUnwrap(row["atMs"]?.double))
            XCTAssertEqual(state.me,row["me"]?.bool); XCTAssertEqual(state.others,row["others"]?.bool)
            XCTAssertEqual(state.source,row["source"]?.string); XCTAssertEqual(state.reason,row["reason"]?.string)
            XCTAssertEqual(state.sinceMs,row["sinceMs"]?.double); XCTAssertEqual(state.fallback,row["fallback"]?.bool)
        }
        XCTAssertEqual(CaptureEvent.read(raw["events"]),manifest.events)
        let events = try JSONParser.parse(Data("[{\"atMs\":0,\"type\":\"future\",\"source\":false},{\"atMs\":1,\"type\":\"othersSource\",\"source\":\"system\",\"reason\":\"lost\",\"extra\":[1,2]}]".utf8))
        let valid = CaptureEvent.read(events)
        XCTAssertEqual(valid.count,1); XCTAssertTrue(CaptureSourceState(events:valid,atMs:1).fallback)
        XCTAssertEqual(CaptureSourceState(events:[],atMs:100).source,nil)
        XCTAssertFalse(CaptureSourceState(events:[],atMs:100).fallback)
    }
    func testActualLibraryReadsBothSharedSparseFixtureTreesWithoutChangingThem() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let script = try XCTUnwrap(Bundle.module.url(forResource:"make",withExtension:"py",subdirectory:"SessionEvents"))
        for name in ["fallback","browser-off-on"] {
            let process = Process(); process.executableURL = URL(fileURLWithPath:"/usr/bin/python3")
            process.arguments = [script.path,root.path,"--case",name]; process.standardOutput = Pipe()
            try process.run(); process.waitUntilExit(); XCTAssertEqual(process.terminationStatus,0)
        }
        let scan = try LibraryScanner(root:root).scan()
        XCTAssertEqual(scan.meetings.count,2)
        for meeting in scan.meetings {
            let before = try Data(contentsOf:meeting.folder.appendingPathComponent("session.json"))
            let loaded = try RecordingLoader.load(directory:meeting.folder)
            XCTAssertEqual(meeting.captureEvents,loaded.events)
            XCTAssertEqual(meeting.audioTracks.count,3); XCTAssertTrue(meeting.canPlaySession)
            if meeting.id.uuidString.lowercased().hasSuffix("006") {
                XCTAssertEqual(meeting.durationMs,960000)
                XCTAssertTrue(CaptureSourceState(events:meeting.captureEvents,atMs:754210).fallback)
                XCTAssertFalse(CaptureSourceState(events:meeting.captureEvents,atMs:900000).fallback)
            } else {
                XCTAssertEqual(meeting.durationMs,20000)
                XCTAssertEqual(meeting.audioTracks.filter { $0.sourceTrackID == "remote-wire-1" }.count,2)
                XCTAssertEqual(meeting.audioTracks.map(\.startOffsetMs),[0,0,10000])
            }
            XCTAssertEqual(try Data(contentsOf:meeting.folder.appendingPathComponent("session.json")),before)
        }
    }
    func testSharedOffOnKeepsOneOpaqueSourceAcrossTwoDistinctTracks() throws {
        let manifest = try RecordingLoader.decode(fixture("browser-off-on.session.json"))
        XCTAssertEqual(manifest.tracks[1].sourceTrackId,"remote-wire-1")
        XCTAssertEqual(manifest.tracks[2].sourceTrackId,"remote-wire-1")
        XCTAssertNotEqual(manifest.tracks[1].id,manifest.tracks[2].id)
        XCTAssertNotEqual(manifest.tracks[1].file,manifest.tracks[2].file)
        XCTAssertNotEqual(manifest.tracks[1].label,manifest.tracks[2].label)
        XCTAssertNil(manifest.tracks[0].sourceTrackId)
        let events = try XCTUnwrap(manifest.events)
        XCTAssertEqual(CaptureSourceState(events:events,atMs:5000).others,false)
        XCTAssertEqual(CaptureSourceState(events:events,atMs:10000).others,true)
    }
    func testOneCheckpointPublishesNewFallbackTrackAndItsEvent() throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:parent) }
        let session = try RecordingSession(parent:parent,title:"Generated",source:"chromium")
        try session.transition(starting:[.init(id:"remote",label:"Remote",kind:"remote",sampleRate:8000,channels:1,sourceTrackId:"opaque")],events:[.init(atMs:0,type:"othersSource",source:"browser",reason:"start"),.init(atMs:0,type:"selection",reason:"start",me:true,others:true)])
        try session.append(id:"remote",pcm:Data(repeating:0,count:16000),offsetMs:0)
        try session.transition(starting:[.init(id:"system",label:"The others",kind:"system",sampleRate:8000,channels:1,labelSource:"device")],ending:["remote"],events:[.init(atMs:1000,type:"othersSource",source:"system",reason:"lost")])
        let loaded = try RecordingLoader.load(directory:session.directory)
        XCTAssertEqual(loaded.events?.last?.source,"system"); XCTAssertEqual(loaded.tracks.count,2)
        XCTAssertEqual(loaded.tracks[0].ended,true); XCTAssertEqual(loaded.tracks[0].endOffsetMs,1000)
        XCTAssertEqual(loaded.tracks[1].labelSource,"device"); XCTAssertNil(loaded.tracks[1].sourceTrackId)
        XCTAssertThrowsError(try session.append(id:"remote",pcm:Data([0,0]),offsetMs:1000))
        XCTAssertThrowsError(try session.addTrack(id:"remote",label:"Other",kind:"remote",sampleRate:8000,channels:1))
        try session.finish()
    }
    func testProcessCrashPublishesFallbackTrackAndEventTogetherAtEveryBoundary() throws {
        for phase in ["filesCreated","audioSynchronized","metadataSynchronized","metadataPublished"] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("CassiniCaptureCrash-" + UUID().uuidString)
            try FileManager.default.createDirectory(at:root,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
            defer { try? FileManager.default.removeItem(at:root) }
            let process = Process(), output = Pipe(), errors = Pipe()
            process.executableURL = Bundle(for:Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("cassini-session-transition-probe")
            process.arguments = [root.path,phase]; process.standardOutput = output; process.standardError = errors
            try process.run()
            defer { if process.isRunning { kill(process.processIdentifier,SIGKILL); process.waitUntilExit() } }
            let fd = output.fileHandleForReading.fileDescriptor
            XCTAssertEqual(fcntl(fd,F_SETFL,fcntl(fd,F_GETFL) | O_NONBLOCK),0)
            var ready = Data(), bytes = [UInt8](repeating:0,count:4096)
            let deadline = Date().addingTimeInterval(7)
            while !ready.contains(10), process.isRunning, Date() < deadline {
                let count = Darwin.read(fd,&bytes,bytes.count)
                if count > 0 { ready.append(contentsOf:bytes.prefix(count)); continue }
                var item = pollfd(fd:fd,events:Int16(POLLIN),revents:0); _ = poll(&item,1,50)
            }
            guard ready.contains(10) else { XCTFail("Persistence probe did not reach \(phase)"); continue }
            let message = try JSONParser.parse(ready)
            let folder = URL(fileURLWithPath:try XCTUnwrap(message["path"]?.string))
            XCTAssertTrue(folder.standardizedFileURL.path.hasPrefix(root.path + "/"))
            // This PID was just created by this test with a generated-only root.
            XCTAssertEqual(kill(process.processIdentifier,SIGKILL),0); process.waitUntilExit()
            XCTAssertEqual(process.terminationReason,.uncaughtSignal); XCTAssertEqual(process.terminationStatus,SIGKILL)
            let raw = try Data(contentsOf:folder.appendingPathComponent("session.json"))
            let manifest = try RecordingLoader.load(directory:folder)
            let hasTrack = manifest.tracks.contains { $0.id == "system" }
            let hasEvent = manifest.events?.contains { $0.source == "system" && $0.reason == "lost" } == true
            XCTAssertEqual(hasTrack,hasEvent,phase)
            XCTAssertEqual(hasTrack,phase == "metadataPublished",phase)
            if phase != "metadataPublished" { XCTAssertEqual(raw,try Data(contentsOf:root.appendingPathComponent("before.json")),phase) }
            XCTAssertEqual(manifest.tracks.first?.frames,8000)
        }
    }
    func testBadOptionalProvenanceDoesNotDamageOtherwisePlayableMetadata() throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:parent) }
        let session = try RecordingSession(parent:parent,title:"Generated",source:"chromium")
        try session.addTrack(id:"remote",label:"Remote",kind:"remote",sampleRate:8000,channels:1)
        try session.append(id:"remote",pcm:Data(repeating:0,count:16000),offsetMs:0); try session.finish()
        let file = session.directory.appendingPathComponent("session.json")
        var raw = try JSONSerialization.jsonObject(with:Data(contentsOf:file)) as! [String:Any]
        var tracks = raw["tracks"] as! [[String:Any]]; tracks[0]["sourceTrackId"] = true; raw["tracks"] = tracks
        raw["events"] = [17,["type":"future","atMs":false,"source":[1,2]],["type":"selection","atMs":1,"me":true,"others":false,"reason":"user"]] as [Any]
        let before = try JSONSerialization.data(withJSONObject:raw); try before.write(to:file)
        let decoded = try RecordingLoader.load(directory:session.directory)
        XCTAssertEqual(decoded.source,"chromium"); XCTAssertEqual(decoded.tracks[0].frames,8000)
        XCTAssertNil(decoded.tracks[0].sourceTrackId)
        let meeting = try XCTUnwrap(LibraryScanner(root:parent).scan().meetings.first)
        XCTAssertEqual(meeting.captureSource,"chromium"); XCTAssertEqual(meeting.durationMs,1000)
        XCTAssertEqual(meeting.captureEvents.count,1)
        XCTAssertEqual(CaptureSourceState(events:meeting.captureEvents,atMs:1).source,nil)
        XCTAssertEqual(try Data(contentsOf:file),before)
    }
    func testEventLimitRejectsTheNextChangeWithoutPublishingHalfATransition() throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:parent) }
        let session = try RecordingSession(parent:parent,title:"Generated",source:"chromium")
        let event = CaptureEvent(atMs:0,type:"selection",reason:"user",me:true,others:false)
        try session.transition(events:Array(repeating:event,count:999))
        let file = session.directory.appendingPathComponent("session.json"), before = try Data(contentsOf:file)
        XCTAssertThrowsError(try session.transition(starting:[.init(id:"new",label:"Generated",kind:"system",sampleRate:8000,channels:1)],events:[event]))
        XCTAssertEqual(try Data(contentsOf:file),before); XCTAssertTrue(session.manifest.tracks.isEmpty)
        try session.finish()
        XCTAssertEqual(session.manifest.events?.count,1000)
        XCTAssertEqual(session.manifest.events?.last?.type,"end")
    }
    func testOpaqueSourceIdentityUsesUTF8BytesAndIsOmittedForNativeSides() throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:parent) }
        let session = try RecordingSession(parent:parent,title:"Generated",source:"chromium")
        for (kind,identity) in [("remote",""),("remote",String(repeating:"é",count:101)),("microphone","opaque"),("system","opaque")] {
            XCTAssertThrowsError(try session.transition(starting:[.init(id:"invalid",label:"Generated",kind:kind,sampleRate:8000,channels:1,sourceTrackId:identity)]))
            XCTAssertTrue(session.manifest.tracks.isEmpty)
        }
        let identity = String(repeating:"é",count:100)
        try session.transition(starting:[.init(id:"valid",label:"Generated",kind:"remote",sampleRate:8000,channels:1,sourceTrackId:identity)])
        XCTAssertEqual(try RecordingLoader.load(directory:session.directory).tracks[0].sourceTrackId,identity)
        try session.finish()
    }
    func testInvalidTransitionLeavesThePreviousCheckpointUntouched() throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:parent) }
        let session = try RecordingSession(parent:parent,title:"Generated",source:"macos")
        try session.transition(events:[.init(atMs:10,type:"selection",reason:"start",me:true,others:true)])
        let file = session.directory.appendingPathComponent("session.json"), before = try Data(contentsOf:file)
        for event in [CaptureEvent(atMs:9,type:"othersSource",source:"system",reason:"lost"),
                      .init(atMs:11,type:"selection",reason:"user",me:false,others:false),
                      .init(atMs:.infinity,type:"othersSource",source:"system",reason:"lost"),
                      .init(atMs:11,type:"othersSource",source:"browser",reason:"restored")] {
            XCTAssertThrowsError(try session.transition(starting:[.init(id:"new",label:"Generated",kind:"system",sampleRate:8000,channels:1)],events:[event]))
            XCTAssertEqual(try Data(contentsOf:file),before)
            XCTAssertTrue(session.manifest.tracks.isEmpty)
        }
        try session.finish()
    }
}
