// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
import Foundation
import CassiniKit
import CassiniRecording
@testable import CassiniBrowserControl

private final class ManualClock: @unchecked Sendable {
    private let lock = NSLock(); private var value: UInt64 = 1_000_000
    func now() -> UInt64 { lock.withLock { value } }
    func advance(_ ms: UInt64) { lock.withLock { value += ms } }
}

/// D52.4 / D52.5 PCM_STALE_AFTER (45 s) through the real host and broker, under an
/// injected clock: armed only while an open span has delivered PCM, every frame
/// counts, and closing takes the EOF path so the recording keeps running.
final class D52TransportLivenessTests: XCTestCase {
    private func start(_ id: String) -> [String:Any] {
        ["type":"start","version":1,"independent":true,"captureId":id,"timelineOriginMs":Int(Date().timeIntervalSince1970*1000),
         "microphone":false,"title":"Generated call","features":["source-outcomes-v1"],"callGeneration":1,"documentGeneration":1]
    }
    private func track(_ id: String) -> [String:Any] {
        ["type":"track","id":id,"kind":"remote","label":"Guest","sampleRate":8000,"channels":1,"sourceTrackId":"source-"+id]
    }
    private func audio(_ id: String, _ sequence: Int, offsetMs: Int = 0) -> [String:Any] {
        ["type":"audio","id":id,"sequence":sequence,"offsetMs":offsetMs,"pcm":Data(repeating:1,count:1600).base64EncodedString()]
    }
    private func ack(_ reply: JSON, _ file: StaticString = #filePath, _ line: UInt = #line) {
        XCTAssertEqual(reply["type"]?.string,"ack","\(reply)",file:file,line:line)
    }

    func testAStaleDeliveringTransportClosesThroughTheEOFPath() async throws {
        let clock = ManualClock(), fixture = try AudioFixture(clock:clock.now)
        do {
            let client = try fixture.client()
            let started = try client.request(start("stale"))
            ack(try client.request(track("a"))); ack(try client.request(audio("a",0)))
            let owner = try XCTUnwrap(fixture.broker.activeCaptures.first { $0.snapshot.directory.path == started["path"]?.string })
            clock.advance(44_999); fixture.broker.closeStaleTransports()
            // Still open; this frame also restarts the watchdog.
            ack(try client.request(audio("a",1,offsetMs:100)))
            clock.advance(44_999); fixture.broker.closeStaleTransports()
            XCTAssertTrue(owner.snapshot.transportAlive)
            clock.advance(1); fixture.broker.closeStaleTransports()
            // With no request pending, the host simply ends the closed transport.
            XCTAssertThrowsError(try client.read(),"the stale transport is closed")
            let deadline = Date().addingTimeInterval(5)
            while owner.snapshot.transportAlive {
                guard Date() < deadline else { return XCTFail("the transport never closed") }
                try await Task.sleep(nanoseconds:10_000_000)
            }
            XCTAssertEqual(owner.snapshot.phase,.recording)
            let last = owner.snapshot.manifest.events?.last { $0.type == "othersSource" }
            XCTAssertEqual(last?.reason,"lost")
        } catch { await fixture.finish(); throw error }
        await fixture.finish()
    }

    func testTheWatchdogIsArmedOnlyWhileAnOpenSpanHasDeliveredPCM() async throws {
        let clock = ManualClock(), fixture = try AudioFixture(clock:clock.now)
        do {
            let client = try fixture.client()
            _ = try client.request(start("armed"))
            // Declared but silent: before the first PCM nothing can go stale.
            ack(try client.request(track("a")))
            clock.advance(300_000); fixture.broker.closeStaleTransports()
            ack(try client.request(audio("a",0)))
            // After the last delivering span ends, nothing can go stale either.
            ack(try client.request(["type":"trackEnd","id":"a","reason":"ended","droppedFrames":0,"endOffsetMs":NSNull()]))
            clock.advance(300_000); fixture.broker.closeStaleTransports()
            ack(try client.request(track("b")))
            XCTAssertEqual(try client.request(["type":"stop","captureId":"armed"])["type"]?.string,"stopped")
        } catch { await fixture.finish(); throw error }
        await fixture.finish()
    }
}
