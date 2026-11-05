// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
@testable import CassiniLibrary

/// #118 r2: the meeting page's turn preparation (what MeetingDetailModel owns), driven with
/// events (E1): a long transcript prepares off the main actor, a newer request or a cancel stops
/// a running preparation so it never delivers, and a cancel by a Library outage resumes.
@MainActor final class TurnPreparationTests: XCTestCase {
    private func alternating(_ count: Int) -> [LibraryTranscriptItem] {
        (0..<count).map { .init(speaker:$0 % 2 == 0 ? "a" : "b",startMs:Int64($0) * 1500,endMs:Int64($0) * 1500 + 1000,text:"Word \($0).") }
    }
    /// A preparer that reports when it starts and waits for the test before it finishes.
    private final class Gated: @unchecked Sendable {
        let lock = NSLock(); var started: [Int] = []; var sawCancel: [Int] = []
        var onStart: (@Sendable (Int) -> Void)?
        var onCancel: (@Sendable (Int) -> Void)?
        let release = DispatchSemaphore(value:0)
        func prepare(_ items: [LibraryTranscriptItem]) throws -> [MeetingPresentation.Turn] {
            lock.withLock { started.append(items.count) }; onStart?(items.count)
            release.wait()
            if Task.isCancelled { lock.withLock { sawCancel.append(items.count) }; onCancel?(items.count); throw CancellationError() }
            return try MeetingPresentation.turns(items,cancellable:true)
        }
    }

    func testALongTranscriptPreparesOffTheMainActor() async {
        let delivered = expectation(description:"turns delivered")
        var turns: [MeetingPresentation.Turn] = []
        final class Thread_: @unchecked Sendable { let lock = NSLock(); var onMain: Bool? }
        let ran = Thread_()
        let preparation = TurnPreparation(prepare:{ items, _ in
            ran.lock.withLock { ran.onMain = Thread.isMainThread }
            return try MeetingPresentation.turns(items,cancellable:true)
        }) { turns = $0; delivered.fulfill() }
        preparation.request(alternating(10_000))
        XCTAssertTrue(turns.isEmpty && preparation.preparing,"request returns before preparing")
        // The main actor keeps running while the preparation works.
        let mainProgress = expectation(description:"main actor progress")
        Task { @MainActor in mainProgress.fulfill() }
        await fulfillment(of:[mainProgress,delivered],timeout:10)
        XCTAssertEqual(turns.count,10_000); XCTAssertFalse(preparation.preparing)
        XCTAssertEqual(ran.lock.withLock { ran.onMain },false,"prepared off the main thread")
    }
    func testANewerRequestCancelsTheRunningOneWhichNeverDelivers() async {
        let gated = Gated(), firstStarted = expectation(description:"first started"), secondStarted = expectation(description:"second started")
        let cancelSeen = expectation(description:"superseded preparation saw its cancellation")
        gated.onStart = { count in if count == 3 { firstStarted.fulfill() } else { secondStarted.fulfill() } }
        gated.onCancel = { count in if count == 3 { cancelSeen.fulfill() } }
        let delivered = expectation(description:"newer delivered")
        var deliveries: [Int] = []
        let preparation = TurnPreparation(prepare:{ items, _ in try gated.prepare(items) }) { deliveries.append($0.count); delivered.fulfill() }
        preparation.request(alternating(3))
        await fulfillment(of:[firstStarted],timeout:5)
        preparation.request(alternating(5))
        await fulfillment(of:[secondStarted],timeout:5)
        gated.release.signal(); gated.release.signal()
        await fulfillment(of:[delivered,cancelSeen],timeout:5)
        XCTAssertEqual(deliveries,[5],"only the newer request delivers")
        XCTAssertEqual(gated.lock.withLock { gated.sawCancel },[3],"the superseded preparation saw its cancellation")
    }
    func testAnOutageCancelsAndRecoveryResumes() async {
        let gated = Gated(), started = expectation(description:"started"); started.expectedFulfillmentCount = 2
        gated.onStart = { _ in started.fulfill() }
        let delivered = expectation(description:"delivered after recovery")
        var deliveries: [Int] = []
        let preparation = TurnPreparation(prepare:{ items, _ in try gated.prepare(items) }) { deliveries.append($0.count); delivered.fulfill() }
        preparation.request(alternating(4))
        preparation.cancel()              // the Library went offline mid-preparation
        preparation.resume()              // it came back with the same words
        await fulfillment(of:[started],timeout:5)
        gated.release.signal(); gated.release.signal()
        await fulfillment(of:[delivered],timeout:5)
        XCTAssertEqual(deliveries,[4])
        preparation.resume()              // nothing to do once the turns are ready
        XCTAssertFalse(preparation.preparing)
    }
}
