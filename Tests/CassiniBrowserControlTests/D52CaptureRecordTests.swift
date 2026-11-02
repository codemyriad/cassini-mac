// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
import Foundation
import CassiniKit
import CassiniLibrary
@_spi(Testing) import CassiniRecording
@_spi(Testing) @testable import CassiniBrowserControl

/// D52.1 R65/R69: recordingDetails.captureRecord v1 in meeting.json.
final class D52CaptureRecordTests: XCTestCase, @unchecked Sendable {
    private func meeting(_ folder: URL) throws -> [String:Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:folder.appendingPathComponent("meeting.json"))) as? [String:Any])
    }
    func testFinalizationWritesTheRecordWithEveryAnnouncedSourceAndNoPaths() async throws {
        let fixture = try AudioFixture()
        do {
            let client = try fixture.client()
            let started = try client.request(["type":"start","version":1,"independent":true,"captureId":"record","timelineOriginMs":Int(Date().timeIntervalSince1970*1000),
                                              "microphone":false,"title":"Call","features":["source-outcomes-v1"]])
            XCTAssertEqual(try client.request(["type":"track","id":"a","kind":"remote","label":"Guest","sampleRate":8000,"channels":1,"sourceTrackId":"guest"])["type"]?.string,"ack")
            XCTAssertEqual(try client.request(["type":"audio","id":"a","sequence":0,"offsetMs":0,"pcm":Data(repeating:1,count:16000).base64EncodedString()])["type"]?.string,"ack")
            XCTAssertEqual(try client.request(["type":"stop","captureId":"record","discoveredSources":[["sourceTrackId":"never","kind":"remote","label":"Host","failed":true]]])["type"]?.string,"stopped")
            let folder = URL(fileURLWithPath:try XCTUnwrap(started["path"]?.string))
            let record = try XCTUnwrap((try meeting(folder)["recordingDetails"] as? [String:Any])?["captureRecord"] as? [String:Any])
            XCTAssertEqual(record["version"] as? Int,1)
            let sources = try XCTUnwrap(record["sources"] as? [[String:Any]])
            XCTAssertEqual(sources.compactMap { $0["sourceTrackId"] as? String },["guest","never"])
            XCTAssertEqual(sources.compactMap { $0["captureOutcome"] as? String },["captured","failed"])
            let tracks = try XCTUnwrap(record["tracks"] as? [[String:Any]])
            XCTAssertEqual(tracks.count,1); XCTAssertNil(tracks[0]["file"]); XCTAssertEqual(tracks[0]["receivedFrames"] as? Int,8000)
            XCTAssertEqual(record["problemKind"] as? String,"capture")
            XCTAssertFalse(String(decoding:try Data(contentsOf:folder.appendingPathComponent("meeting.json")),as:UTF8.self).contains(folder.path))
            // An identical rewrite keeps the revision.
            let revision = try meeting(folder)["revision"] as? Int
            try CaptureRecordWriter.write(try RecordingLoader.load(directory:folder),directory:folder)
            XCTAssertEqual(try meeting(folder)["revision"] as? Int,revision)
        } catch { await fixture.finish(); throw error }
        await fixture.finish()
    }
    // MARK: #104 review: the record is written before the capture is saved, and failures stay retryable

    private final class Persist: @unchecked Sendable {
        let lock = NSLock(); var calls = 0; var failures = 0; var hold: DispatchSemaphore?; var entered: XCTestExpectation?
        func run(_ manifest: RecordingManifest, _ directory: URL) throws {
            let (hold,entered,fail): (DispatchSemaphore?,XCTestExpectation?,Bool) = lock.withLock {
                calls += 1; let fail = failures > 0; if fail { failures -= 1 }; return (self.hold,self.entered,fail)
            }
            entered?.fulfill(); hold?.wait()
            if fail { throw CocoaError(.fileWriteOutOfSpace) }
            try CaptureRecordWriter.write(manifest,directory:directory)
        }
    }
    private func native(_ persist: Persist) throws -> (URL,BrowserAudioBroker,OwnedBrowserCapture) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CassiniRecord-"+UUID().uuidString)
        let broker = BrowserAudioBroker(make:{ _,_ in throw BrowserIPCError.unavailable },created:{ _,_ in },stopNative:{ _,reply in reply(nil) },
                                        persistRecord:{ try persist.run($0,$1) })
        let owner = try OwnedBrowserCapture(parent:root,title:"Native",microphone:true,browser:false)
        let writer = owner.nativeWriter(side:.me)
        try writer.addTrack(id:"mic",label:"Me",kind:"microphone",sampleRate:8000,channels:1)
        try writer.appendNative(id:"mic",pcm:Data(repeating:1,count:16000),offsetMs:0)
        try broker.ownNative(owner)
        return (root,broker,owner)
    }
    private func record(_ owner: OwnedBrowserCapture) throws -> [String:Any]? {
        let folder = owner.snapshot.directory
        guard FileManager.default.fileExists(atPath:folder.appendingPathComponent("meeting.json").path) else { return nil }
        return (try meeting(folder)["recordingDetails"] as? [String:Any])?["captureRecord"] as? [String:Any]
    }
    /// The capture stays saving (so the Library keeps its move protection) and owned while the
    /// metadata write is paused; it is saved only after the record is written.
    func testTheCaptureStaysSavingUntilItsRecordIsWritten() async throws {
        let persist = Persist(); persist.hold = DispatchSemaphore(value:0); persist.entered = expectation(description:"record write started")
        let (root,broker,owner) = try native(persist); defer { try? FileManager.default.removeItem(at:root) }
        let finishing = Task { try await broker.finish(owner,reason:.user) }
        await fulfillment(of:[persist.entered!],timeout:5)
        XCTAssertEqual(owner.snapshot.phase,.saving)
        XCTAssertTrue(broker.activeCaptures.contains { $0 === owner })
        XCTAssertNil(try record(owner))
        persist.hold?.signal()
        try await finishing.value
        XCTAssertEqual(owner.snapshot.phase,.saved)
        XCTAssertFalse(broker.activeCaptures.contains { $0 === owner })
        XCTAssertNotNil(try record(owner))
    }
    /// A final session that reached disk although finalization failed (here the final
    /// checkpoint fails after publishing) still gets its portable record; the error is reported.
    func testADurablyInterruptedSessionStillWritesItsRecord() async throws {
        let persist = Persist()
        let (root,broker,owner) = try native(persist); defer { try? FileManager.default.removeItem(at:root) }
        owner.setCheckpointObserver { phase in if phase == .metadataPublished { throw CocoaError(.fileWriteUnknown) } }
        do { try await broker.finish(owner,reason:.user); XCTFail("the close failure is reported") } catch {}
        XCTAssertEqual(owner.snapshot.phase,.saved)
        XCTAssertEqual(persist.calls,1)
        let stored = try XCTUnwrap(try record(owner))
        XCTAssertEqual((stored["tracks"] as? [[String:Any]])?.count,1)
        XCTAssertEqual(try RecordingLoader.load(directory:owner.snapshot.directory).state,"completed","the published final session")
    }
    /// A failed record write keeps the capture saving and owned; a retry writes the record once
    /// and then saves it. After the attempt limit the capture is saved without the record.
    func testAFailedRecordWriteIsRetriedThenGivenUp() async throws {
        let persist = Persist(); persist.failures = 1
        let (root,broker,owner) = try native(persist); defer { try? FileManager.default.removeItem(at:root) }
        do { try await broker.finish(owner,reason:.user); XCTFail("the record failure is reported") } catch {}
        XCTAssertEqual(owner.snapshot.phase,.saving); XCTAssertTrue(owner.recordPending)
        XCTAssertTrue(broker.activeCaptures.contains { $0 === owner })
        await broker.retryPendingRecords()
        XCTAssertEqual(owner.snapshot.phase,.saved); XCTAssertNotNil(try record(owner)); XCTAssertEqual(persist.calls,2)
        XCTAssertFalse(broker.activeCaptures.contains { $0 === owner })

        let failing = Persist(); failing.failures = 1000
        let (other,broker2,owner2) = try native(failing); defer { try? FileManager.default.removeItem(at:other) }
        do { try await broker2.finish(owner2,reason:.user) } catch {}
        for _ in 0..<10 where owner2.snapshot.phase != .saved { await broker2.retryPendingRecords() }
        XCTAssertEqual(owner2.snapshot.phase,.saved,"saved without the record after the attempt limit")
        XCTAssertEqual(failing.calls,BrowserAudioBroker.recordAttemptLimit)
        XCTAssertNil(try record(owner2))
        XCTAssertFalse(broker2.activeCaptures.contains { $0 === owner2 })
    }
    func testMergeKeepsUnknownFieldsReplacesExpectationAndNeverDowngrades() {
        let stored: [String:Any] = ["version":1,"future":true,
            "sources":[["sourceTrackId":"a","captureOutcome":"neverAudio","captureExpected":false,"extra":1]],
            "tracks":[["id":"t","frames":1,"note":"keep"]],"events":[]]
        let fresh: [String:Any] = ["version":1,"sources":[["sourceTrackId":"a","captureOutcome":"captured"],["sourceTrackId":"b","captureOutcome":"failed"]],
            "tracks":[["id":"t","frames":2]],"events":[["type":"end"]]]
        let merged = CaptureRecordWriter.merge(stored,fresh)!
        XCTAssertEqual(merged["future"] as? Bool,true)
        let sources = merged["sources"] as! [[String:Any]]
        XCTAssertEqual(sources.count,2); XCTAssertEqual(sources[0]["captureOutcome"] as? String,"captured")
        XCTAssertNil(sources[0]["captureExpected"],"captureExpected is replaced, not merged"); XCTAssertEqual(sources[0]["extra"] as? Int,1)
        XCTAssertEqual((merged["tracks"] as! [[String:Any]])[0]["note"] as? String,"keep")
        XCTAssertEqual((merged["tracks"] as! [[String:Any]])[0]["frames"] as? Int,2)
        XCTAssertNil(CaptureRecordWriter.merge(["version":2,"sources":[]],fresh),"A newer record is left untouched")
    }
}
