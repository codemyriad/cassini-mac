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

    /// stale-watchdog.json (D52.5) through the watchdog the audio peer uses.
    func testSharedStaleWatchdogVectors() throws {
        let url = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("browser-protocol/conformance/multistream/stale-watchdog.json")
        let file = try JSONParser.parse(Data(contentsOf:url))
        XCTAssertEqual(file["constants"]?["PCM_STALE_AFTER"]?.int,Int(AudioTransportWatchdog.staleAfter))
        let cases = try XCTUnwrap(file["cases"]?.array)
        XCTAssertEqual(cases.count,24)
        for vector in cases {
            let name = try XCTUnwrap(vector["name"]?.string), frames = try XCTUnwrap(vector["frames"]?.array)
            func closed(by now: Int) -> Bool {
                var watchdog = AudioTransportWatchdog()
                for frame in frames {
                    guard let at = frame["atMs"]?.int, at <= now else { break }
                    let id = frame["id"]?.string ?? ""
                    let kind: AudioTransportWatchdog.Frame
                    switch frame["frame"]?.string {
                    case "control": continue   // control-connection frames never reach the audio peer
                    case "documentChanged":
                        // D57: the recording's status, as BrowserAudioBroker.documentChanged feeds it.
                        let page = frame["pageState"]?.string.flatMap(BrowserCallLifecycle.Page.init(rawValue:))
                        if !watchdog.document(page:page,generation:frame["documentGeneration"]?.string,at:UInt64(at)) { return true }
                        continue
                    case "track": kind = .track(id,generation:frame["documentGeneration"]?.string)
                    case "audio": kind = .audio(id)
                    case "trackEnd": kind = .trackEnd(id)
                    case "stop": kind = .stop
                    default: kind = .other
                    }
                    if !watchdog.receive(kind,at:UInt64(at)) { return true }
                }
                return watchdog.isStale(at:UInt64(now))
            }
            for probe in try XCTUnwrap(vector["probes"]?.array) {
                let at = try XCTUnwrap(probe["atMs"]?.int)
                XCTAssertEqual(closed(by:at),probe["closed"]?.bool,"\(name) at \(at)")
            }
            if let close = vector["closeAtMs"]?.int {
                XCTAssertTrue(closed(by:close),name); XCTAssertFalse(closed(by:close - 1),name)
            }
        }
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
            let closed = fixture.closures.next("the stale transport closed through EOF")
            clock.advance(1); fixture.broker.closeStaleTransports()
            // With no request pending, the host simply ends the closed transport.
            XCTAssertThrowsError(try client.read(),"the stale transport is closed")
            await fulfillment(of:[closed],timeout:5)
            XCTAssertFalse(owner.snapshot.transportAlive)
            XCTAssertEqual(owner.snapshot.phase,.recording)
            let last = owner.snapshot.manifest.events?.last { $0.type == "othersSource" }
            XCTAssertEqual(last?.reason,"lost")
        } catch { await fixture.finish(); throw error }
        await fixture.finish()
    }

    /// D57 through the real host and broker: a navigating status retires the gone document's
    /// spans and those declared while it departs; the next document's span arms again.
    func testAGoneDocumentsSpansNeverCloseTheTransport() async throws {
        let clock = ManualClock(), fixture = try AudioFixture(clock:clock.now)
        do {
            let client = try fixture.client()
            _ = try client.request(start("doc"))
            ack(try client.request(track("a"))); ack(try client.request(audio("a",0)))
            fixture.broker.documentChanged(captureID:"doc",page:.present,documentGeneration:"doc-1")
            fixture.broker.documentChanged(captureID:"other",page:.navigating,documentGeneration:"doc-1")
            fixture.broker.documentChanged(captureID:"doc",page:.navigating,documentGeneration:"doc-1")
            ack(try client.request(track("late"))); ack(try client.request(audio("late",0)))
            clock.advance(300_000); fixture.broker.closeStaleTransports()
            // Still open: a status after the deadline only counts when the watchdog is armed.
            fixture.broker.documentChanged(captureID:"doc",page:.present,documentGeneration:"doc-2")
            ack(try client.request(track("b"))); ack(try client.request(audio("b",0)))
            clock.advance(44_999); fixture.broker.closeStaleTransports()
            ack(try client.request(audio("b",1,offsetMs:100)))
            clock.advance(45_000)
            // The next document's status, arriving at the deadline, is too late: it closes.
            fixture.broker.documentChanged(captureID:"doc",page:.present,documentGeneration:"doc-2")
            XCTAssertThrowsError(try client.read(),"the stale transport is closed")
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

    /// #113 review r2: a terminal refusal retires its span from the watchdog. The owner closed
    /// the span and the extension fences its later packets, so nothing delivers: the transport
    /// must not close at 45 s. A new span arms it again.
    func testATerminalRefusalRetiresItsSpanFromTheWatchdog() async throws {
        let clock = ManualClock(), fixture = try AudioFixture(clock:clock.now)
        do {
            let client = try fixture.client()
            let started = try client.request(start("refused"))
            ack(try client.request(track("a"))); ack(try client.request(audio("a",0)))
            let owner = try XCTUnwrap(fixture.broker.activeCaptures.first { $0.snapshot.directory.path == started["path"]?.string })
            var broken = audio("a",1,offsetMs:100); broken["pcm"] = "not base64!"
            let refused = try client.request(broken)
            XCTAssertEqual(refused["scope"]?.string,"source","\(refused)"); XCTAssertEqual(refused["id"]?.string,"a")
            XCTAssertTrue(owner.isRetired("a"))
            clock.advance(45_000); fixture.broker.closeStaleTransports()
            clock.advance(100_000); fixture.broker.closeStaleTransports()
            XCTAssertTrue(owner.snapshot.transportAlive,"no delivering span is left to go stale")
            // A closed transport would fail the next request; an open one acks it.
            // The transport still carries the call: a new span arms the watchdog again.
            ack(try client.request(track("b"))); ack(try client.request(audio("b",0)))
            clock.advance(44_999); fixture.broker.closeStaleTransports()
            // Still open 1 ms before the deadline: this request is answered (and is activity).
            ack(try client.request(track("c")))
            let closed = fixture.closures.next("the new span went stale")
            clock.advance(45_000); fixture.broker.closeStaleTransports()
            XCTAssertThrowsError(try client.read(),"the stale transport is closed")
            await fulfillment(of:[closed],timeout:5)
            XCTAssertFalse(owner.snapshot.transportAlive)
        } catch { await fixture.finish(); throw error }
        await fixture.finish()
    }
    /// #113 review r2: a refused frame is activity but changes no span. A refused declaration
    /// opens nothing, so its refused audio cannot arm the watchdog.
    func testRefusedFramesAreActivityButOpenNoSpan() async throws {
        let clock = ManualClock(), fixture = try AudioFixture(clock:clock.now)
        do {
            let client = try fixture.client()
            let started = try client.request(start("refused-declaration"))
            let owner = try XCTUnwrap(fixture.broker.activeCaptures.first { $0.snapshot.directory.path == started["path"]?.string })
            var invalid = track("x"); invalid["sampleRate"] = 1
            XCTAssertEqual(try client.request(invalid)["scope"]?.string,"source")
            XCTAssertEqual(try client.request(audio("x",0))["type"]?.string,"error")
            clock.advance(45_000); fixture.broker.closeStaleTransports()
            clock.advance(100_000); fixture.broker.closeStaleTransports()
            // A closed transport would fail this request; an open one acks it.
            ack(try client.request(track("y")))
            XCTAssertTrue(owner.snapshot.transportAlive)
        } catch { await fixture.finish(); throw error }
        await fixture.finish()
    }

    /// #113 review r2 follow-up: a valid Stop ends every span when it arrives, so a save that
    /// outlasts PCM_STALE_AFTER does not let the watchdog close the pipe before "stopped".
    func testASlowSaveAfterStopIsNotClosedByTheWatchdog() async throws {
        let entered = DispatchSemaphore(value:0), release = DispatchSemaphore(value:0)
        let clock = ManualClock(), fixture = try AudioFixture(stop:{ _,reply in
            entered.signal()
            DispatchQueue.global().async { _ = release.wait(timeout:.now() + 10); reply(nil) }
        },clock:clock.now)
        do {
            let client = try fixture.client()
            _ = try client.request(start("slow-save"))
            ack(try client.request(track("a"))); ack(try client.request(audio("a",0)))
            let reply = Reply()
            DispatchQueue.global().async { reply.store(Result { try client.request(["type":"stop","captureId":"slow-save"]) }) }
            XCTAssertEqual(entered.wait(timeout:.now() + 5),.success,"the save started")
            clock.advance(45_000); fixture.broker.closeStaleTransports()
            clock.advance(100_000); fixture.broker.closeStaleTransports()
            release.signal()
            let stopped = try await reply.value()
            XCTAssertEqual(stopped["type"]?.string,"stopped","\(stopped)")
        } catch { await fixture.finish(); throw error }
        await fixture.finish()
    }
}

/// One reply from a request made on another thread, awaited as an event.
private final class Reply: @unchecked Sendable {
    private let lock = NSLock(); private var result: Result<JSON,Error>?; private var waiter: CheckedContinuation<JSON,Error>?
    func store(_ value: Result<JSON,Error>) {
        let waiting: CheckedContinuation<JSON,Error>? = lock.withLock { if let w = waiter { waiter = nil; return w }; result = value; return nil }
        waiting?.resume(with:value)
    }
    func value() async throws -> JSON {
        try await withCheckedThrowingContinuation { continuation in
            let ready: Result<JSON,Error>? = lock.withLock { if let r = result { return r }; waiter = continuation; return nil }
            if let ready { continuation.resume(with:ready) }
        }
    }
}
