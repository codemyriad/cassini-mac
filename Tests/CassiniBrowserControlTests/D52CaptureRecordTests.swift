// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
import Foundation
import CassiniKit
import CassiniLibrary
@_spi(Testing) import CassiniRecording
@_spi(Testing) @testable import CassiniBrowserControl

/// D52.1 R65/R69: recordingDetails.captureRecord v1 in meeting.json.
final class D52CaptureRecordTests: XCTestCase, @unchecked Sendable {
    func testMixedRouteSurvivesFinalizationMetadataEditsAndSessionRemoval() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("D74-route-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let owner = try OwnedBrowserCapture(parent:root,title:"Mixed site meeting",microphone:false,browser:false)
        let folder = owner.snapshot.directory, id = owner.snapshot.manifest.id
        try CaptureRecordWriter.writeMixedRoute(site:"Synthetic call",directory:folder,id:id)
        let writer = owner.nativeWriter(side:.others)
        try writer.addTrack(id:"system",label:"This computer",kind:"system",sampleRate:8000,channels:1)
        try writer.appendNative(id:"system",pcm:Data(repeating:1,count:1600),offsetMs:0)
        let broker = BrowserAudioBroker(make:{ _,_,_ in throw BrowserIPCError.unavailable },created:{ _,_ in },stopNative:{ _,reply in reply(nil) })
        try broker.ownNative(owner); try await broker.finish(owner)
        try MeetingMetadataWriter(directory:folder,id:id).transaction { $0["title"] = "Edited meeting" }
        let route = try XCTUnwrap((try meeting(folder)["recordingDetails"] as? [String:Any])?["othersRoute"] as? [String:String])
        XCTAssertEqual(route,["source":"system","reason":"mixedSiteSignal","site":"Synthetic call"])
        try FileManager.default.removeItem(at:folder.appendingPathComponent("session.json"))
        let report = RecordingDetailsReport(.load(folder:folder,lifecycle:.saved,title:"Edited meeting",transcriptDone:false))
        XCTAssertEqual(report.notes.map(\.id),["details.othersRoute.mixedGeneric"])
        XCTAssertEqual(report.notes[0].render(language:.en,locale:Locale(identifier:"en_GB")),"This call mixed all remote voices into one stream, so Cassini recorded them from the computer’s audio.")
        // Future file values stay intact and make no known-route claim.
        try MeetingMetadataWriter(directory:folder,id:id).transaction { metadata in
            var details = metadata["recordingDetails"] as! [String:Any]
            details["othersRoute"] = ["source":"future source","reason":"future reason","site":"future site","future":17] as [String:Any]
            metadata["recordingDetails"] = details
        }
        try MeetingMetadataWriter(directory:folder,id:id).transaction { $0["title"] = "Another edit" }
        let future = try XCTUnwrap((try meeting(folder)["recordingDetails"] as? [String:Any])?["othersRoute"] as? [String:Any])
        XCTAssertEqual(future["source"] as? String,"future source"); XCTAssertEqual(future["future"] as? Int,17)
        XCTAssertTrue(RecordingDetailsReport(.load(folder:folder,lifecycle:.saved,title:"Another edit",transcriptDone:false)).notes.isEmpty)
    }
    func testMixedRouteSiteUsesUnicodeCodePointsForMetadataAndGenericDisplay() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("D74-unicode-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let owner = try OwnedBrowserCapture(parent:root,title:"Unicode route bounds",microphone:false,browser:false)
        let folder = owner.snapshot.directory, id = owner.snapshot.manifest.id
        for site in [String(repeating:"🛰",count:200),"e"+String(repeating:"\u{301}",count:199)] {
            try CaptureRecordWriter.writeMixedRoute(site:site,directory:folder,id:id)
            XCTAssertEqual(((try meeting(folder)["recordingDetails"] as? [String:Any])?["othersRoute"] as? [String:String])?["site"],site)
            let report = RecordingDetailsReport(.load(folder:folder,lifecycle:.recording,title:"Unicode route bounds",transcriptDone:false))
            XCTAssertEqual(report.notes.map(\.id),["details.othersRoute.mixedGeneric"])
            XCTAssertTrue(try XCTUnwrap(report.notes.first).values.isEmpty,"Adapter IDs remain metadata, never displayed arguments")
        }
        for site in [String(repeating:"a",count:201),"e"+String(repeating:"\u{301}",count:200)] {
            XCTAssertThrowsError(try CaptureRecordWriter.writeMixedRoute(site:site,directory:folder,id:id))
            try MeetingMetadataWriter(directory:folder,id:id).transaction { metadata in
                var details = metadata["recordingDetails"] as! [String:Any]
                details["othersRoute"] = ["source":"system","reason":"mixedSiteSignal","site":site]
                metadata["recordingDetails"] = details
            }
            XCTAssertTrue(RecordingDetailsReport(.load(folder:folder,lifecycle:.recording,title:"Unicode route bounds",transcriptDone:false)).notes.isEmpty,"Malformed imported metadata must not make a route claim")
        }
        try await owner.finish()
    }
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
        let broker = BrowserAudioBroker(make:{ _,_,_ in throw BrowserIPCError.unavailable },created:{ _,_ in },stopNative:{ _,reply in reply(nil) },
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
    /// #104 delta review: a pending-record scan never holds the broker lock while a capture's
    /// I/O queue is busy, so Stop (expectResume) and Quit (closeAdmission) stay responsive while
    /// the metadata write is stalled.
    func testARetryScanNeverBlocksBrokerControlWhilePersistenceStalls() async throws {
        let persist = Persist(); persist.hold = DispatchSemaphore(value:0); persist.entered = expectation(description:"record write stalled")
        let (root,broker,owner) = try native(persist); defer { try? FileManager.default.removeItem(at:root) }
        let finishing = Task { try await broker.finish(owner,reason:.user) }
        await fulfillment(of:[persist.entered!],timeout:5)
        XCTAssertTrue(owner.snapshot.recordPending,"the cached snapshot says the record is pending")
        // The scan has read the pending state and released the broker lock, while the record
        // write is still stalled: only then are the control calls checked.
        let scanned = expectation(description:"scan read pending and released the lock")
        broker.observeRetryScan { capture in if capture === owner { scanned.fulfill() } }
        let scanning = Task { await broker.retryPendingRecords() }
        await fulfillment(of:[scanned],timeout:5)
        let responsive = expectation(description:"broker control calls return")
        DispatchQueue.global().async {
            broker.expectResume(owner,callGeneration:nil)
            _ = broker.retainedCaptureIDs
            broker.closeAdmission()
            responsive.fulfill()
        }
        await fulfillment(of:[responsive],timeout:2)
        persist.hold?.signal()
        try await finishing.value
        await scanning.value
        XCTAssertEqual(owner.snapshot.phase,.saved); XCTAssertFalse(owner.snapshot.recordPending)
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
