// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
import Foundation
import CassiniKit
import CassiniRecording
@testable import CassiniBrowserControl

private final class TerminalDrainCount: @unchecked Sendable {
    private let lock = NSLock(); private var value = 0
    func increment() { lock.withLock { value += 1 } }
    var count: Int { lock.withLock { value } }
}
final class OwnedTerminalEventTests: XCTestCase {
    private func temporary() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CassiniEnd-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:false); return root
    }
    func testEveryClaimedTriggerSurvivesTheLaterGenericBrowserStopAndTail() async throws {
        for reason in CaptureEndReason.allCases {
            let root = try temporary(); defer { try? FileManager.default.removeItem(at:root) }
            let owner = try OwnedBrowserCapture(parent:root,title:"Generated",microphone:false)
            try owner.browserTrack(id:"remote",label:"Remote",kind:"remote",sampleRate:8000,channels:1)
            XCTAssertTrue(owner.requestEnd(reason,atMs:100))
            try owner.browserAudio(id:"remote",sequence:0,offsetMs:500,pcm:Data(repeating:0,count:8000))
            try await owner.finish(reason:.user,atMs:10)
            let file = owner.snapshot.directory.appendingPathComponent("session.json"), before = try Data(contentsOf:file)
            let saved = try RecordingLoader.load(directory:owner.snapshot.directory)
            XCTAssertEqual(saved.events?.filter { $0.type == "end" }.count,1)
            XCTAssertEqual(saved.events?.last?.reason,reason.rawValue)
            XCTAssertEqual(saved.events?.last?.atMs,1000,"Accepted tail extends the earlier Stop trigger")
            try await owner.finish(reason:.error,atMs:2000)
            XCTAssertEqual(try Data(contentsOf:file),before)
        }
    }
    func testInvalidTimeCannotClaimIntentOrMutateTheSession() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at:root) }
        let owner = try OwnedBrowserCapture(parent:root,title:"Generated",microphone:false,browser:false)
        XCTAssertFalse(owner.requestEnd(.disk,atMs:.nan))
        XCTAssertFalse(owner.requestEnd(.disk,atMs:-1))
        XCTAssertTrue(owner.requestEnd(.appQuit,atMs:100))
        XCTAssertFalse(owner.requestEnd(.user,atMs:200))
        try await owner.finish()
        XCTAssertEqual(owner.snapshot.manifest.events?.last,.init(atMs:100,type:"end",reason:"appQuit"))
    }
    func testBrokerSharesOneDrainAndPreservesTheOriginalDiskTrigger() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at:root) }
        let owner = try OwnedBrowserCapture(parent:root,title:"Generated",microphone:false,browser:false)
        let count = TerminalDrainCount()
        let broker = BrowserAudioBroker(make:{ _,_ in owner },created:{ _,_ in },stopNative:{ _,reply in count.increment(); reply(nil) })
        try broker.ownNative(owner)
        XCTAssertTrue(owner.requestEnd(.disk,atMs:3000))
        async let first: Void = broker.finish(owner,reason:.user,atMs:100)
        async let second: Void = broker.finish(owner,reason:.appQuit,atMs:5000)
        _ = try await (first,second)
        XCTAssertEqual(count.count,1)
        XCTAssertEqual(owner.snapshot.manifest.events?.last,.init(atMs:3000,type:"end",reason:"disk"))
    }
    func testQuitOfAnOwnerNotYetPublishedToUIUsesItsMonotonicClock() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at:root) }
        let owner = try OwnedBrowserCapture(parent:root,title:"Generated",microphone:false,browser:false)
        owner.setTimelineOrigin(ProcessInfo.processInfo.systemUptime-5)
        let broker = BrowserAudioBroker(make:{ _,_ in owner },created:{ _,_ in },stopNative:{ _,reply in reply(nil) })
        try broker.ownNative(owner)
        _ = await broker.finishAll(reason:.appQuit)
        let end = try XCTUnwrap(owner.snapshot.manifest.events?.last)
        XCTAssertEqual(end.reason,"appQuit")
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(end.atMs),5000)
        XCTAssertLessThan(try XCTUnwrap(end.atMs),60000)
    }
    func testInvalidBrokerEndTimeCannotStopNativeInputs() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at:root) }
        let owner = try OwnedBrowserCapture(parent:root,title:"Generated",microphone:false,browser:false)
        let count = TerminalDrainCount()
        let broker = BrowserAudioBroker(make:{ _,_ in owner },created:{ _,_ in },stopNative:{ _,reply in count.increment(); reply(nil) })
        try broker.ownNative(owner)
        do { try await broker.finish(owner,reason:.disk,atMs:.nan); XCTFail("Invalid time must be rejected") }
        catch { }
        XCTAssertEqual(count.count,0); XCTAssertEqual(owner.snapshot.phase,.recording)
        try await broker.finish(owner,reason:.user,atMs:100)
        XCTAssertEqual(owner.snapshot.manifest.events?.last?.reason,"user")
    }

}
