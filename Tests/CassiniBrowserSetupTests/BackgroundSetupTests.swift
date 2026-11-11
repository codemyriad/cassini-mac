// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
import Foundation
import Observation
@testable import CassiniBrowserSetup

private actor FakeSetupClock {
    private(set) var delays: [Double] = []
    private var sleepers: [UUID:CheckedContinuation<Void,Error>] = [:]
    private var cancelled: Set<UUID> = []
    private var events: [(Int,Int,XCTestExpectation)] = []
    var pending: Int { sleepers.count }
    func event(_ count: Int, pending: Int = 1) -> XCTestExpectation {
        let event = XCTestExpectation(description:"Retry clock registered \(count) delays, \(pending) pending")
        events.append((count,pending,event)); changed(); return event
    }
    private func changed() {
        let ready = events.filter { $0.0 == delays.count && $0.1 == pending }
        events.removeAll { $0.0 == delays.count && $0.1 == pending }
        for (_,_,event) in ready { event.fulfill() }
    }
    func sleep(_ seconds: Double) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void,Error>) in
                delays.append(seconds)
                if cancelled.remove(id) != nil || Task.isCancelled { continuation.resume(throwing:CancellationError()) }
                else { sleepers[id] = continuation }
                changed()
            }
        } onCancel: { Task { await self.cancel(id) } }
    }
    private func cancel(_ id: UUID) {
        if let continuation = sleepers.removeValue(forKey:id) { continuation.resume(throwing:CancellationError()) }
        else { cancelled.insert(id) }
        changed()
    }
    func advance() {
        let current = sleepers; sleepers = [:]
        for continuation in current.values { continuation.resume() }
        changed()
    }
}
private actor SetupAttempts {
    private(set) var count = 0
    private(set) var offMain = true
    private var failures: [BrowserSetupFailure]
    private var gate: CheckedContinuation<Void,Never>?
    private var events: [(Int,XCTestExpectation)] = []
    func event(_ count: Int) -> XCTestExpectation {
        let event = XCTestExpectation(description:"Installer entered \(count) attempts")
        if self.count >= count, gate != nil { event.fulfill() } else { events.append((count,event)) }
        return event
    }
    private func entered() {
        let ready = events.filter { $0.0 <= count }; events.removeAll { $0.0 <= count }
        for (_,event) in ready { event.fulfill() }
    }
    let blocking: Bool
    init(_ failures: [BrowserSetupFailure] = [], blocking: Bool = false) { self.failures = failures; self.blocking = blocking }
    func install() async throws {
        count += 1; offMain = offMain && !Thread.isMainThread
        if blocking { await withCheckedContinuation { gate = $0; entered() } }
        else { entered() }
        if !failures.isEmpty { throw failures.removeFirst() }
    }
    func release() { gate?.resume(); gate = nil }
}
final class BackgroundSetupTests: XCTestCase {
    func testBackoffAndJitterBounds() {
        var middle = BrowserSetupBackoff(), low = BrowserSetupBackoff(), high = BrowserSetupBackoff()
        for base in [5.0,10,20,40,80,160,300,300] {
            XCTAssertEqual(middle.next(unit:0.5),base,accuracy:0.00001)
            XCTAssertEqual(low.next(unit:0),base * 0.8,accuracy:0.00001)
            XCTAssertEqual(high.next(unit:1),base * 1.2,accuracy:0.00001)
        }
        middle.reset(); XCTAssertEqual(middle.next(unit:0.5),5)
    }
    @MainActor func testFakeClockRetryAndSuccessStopsTimer() async throws {
        let clock = FakeSetupClock(), attempts = SetupAttempts([.temporary,.temporary])
        let setup = BackgroundBrowserSetup(install:{ try await attempts.install() },sleep:{ try await clock.sleep($0) },random:{ 0.5 })
        defer { setup.stop() }
        setup.trigger()
        await fulfillment(of:[await clock.event(1)],timeout:5)
        XCTAssertEqual(setup.state,.failed(.temporary))
        await clock.advance()
        await fulfillment(of:[await clock.event(2)],timeout:5)
        await clock.advance()
        await waitForSetupState(setup,.waiting)
        let delays = await clock.delays, count = await attempts.count, pending = await clock.pending
        XCTAssertEqual(delays,[5,10]); XCTAssertEqual(count,3); XCTAssertEqual(pending,0)
        let offMain = await attempts.offMain; XCTAssertTrue(offMain)
    }
    @MainActor func testActivationOrRetryResetsBackoffAndCancelsOldTimer() async throws {
        let clock = FakeSetupClock(), attempts = SetupAttempts([.temporary,.temporary,.temporary])
        let setup = BackgroundBrowserSetup(install:{ try await attempts.install() },sleep:{ try await clock.sleep($0) },random:{ 0.5 })
        defer { setup.stop() }
        setup.trigger(); await fulfillment(of:[await clock.event(1)],timeout:5)
        await clock.advance(); await fulfillment(of:[await clock.event(2)],timeout:5)
        setup.trigger(); await fulfillment(of:[await clock.event(3)],timeout:5)
        let delays = await clock.delays; XCTAssertEqual(delays,[5,10,5])
        await clock.advance(); await waitForSetupState(setup,.waiting)
        let count = await attempts.count; XCTAssertEqual(count,4)
    }
    @MainActor func testPermanentFailuresOnlyRetryOnTrigger() async throws {
        for failure: BrowserSetupFailure in [.noBrowser,.unwritable,.unsafe] {
            let clock = FakeSetupClock(), attempts = SetupAttempts([failure])
            let setup = BackgroundBrowserSetup(install:{ try await attempts.install() },sleep:{ try await clock.sleep($0) })
            setup.trigger(); await waitForSetupState(setup,.failed(failure))
            let delays = await clock.delays; XCTAssertEqual(delays,[])
            await clock.advance(); let count = await attempts.count; XCTAssertEqual(count,1)
            setup.trigger(); await waitForSetupState(setup,.waiting); setup.stop()
        }
    }
    @MainActor func testEventsDuringAttemptCoalesceWithoutBlockingUIActor() async throws {
        let attempts = SetupAttempts(blocking:true)
        let setup = BackgroundBrowserSetup(install:{ try await attempts.install() })
        defer { setup.stop() }
        setup.trigger(); await fulfillment(of:[await attempts.event(1)],timeout:5)
        // This code is on the UI actor while the worker is still blocked.
        for _ in 0..<20 { setup.trigger() }
        let count = await attempts.count; XCTAssertEqual(count,1)
        await attempts.release(); await fulfillment(of:[await attempts.event(2)],timeout:5)
        await attempts.release(); await waitForSetupState(setup,.waiting)
        let final = await attempts.count, offMain = await attempts.offMain
        XCTAssertEqual(final,2); XCTAssertTrue(offMain)
    }
    @MainActor func testStopCancelsScheduledRetry() async throws {
        let clock = FakeSetupClock(), attempts = SetupAttempts([.temporary])
        let setup = BackgroundBrowserSetup(install:{ try await attempts.install() },sleep:{ try await clock.sleep($0) })
        setup.trigger(); await fulfillment(of:[await clock.event(1)],timeout:5)
        setup.stop(); await fulfillment(of:[await clock.event(1,pending:0)],timeout:5)
        await clock.advance(); setup.trigger()
        let count = await attempts.count; XCTAssertEqual(count,1)
    }
    func testFailureClassificationSurvivesXPCAndDoesNotRetryPermissions() {
        for failure: BrowserSetupFailure in [.temporary,.noBrowser,.unwritable,.unsafe] {
            XCTAssertEqual(BrowserSetupFailure(failure.nsError),failure)
            XCTAssertEqual(BrowserSetupFailure(failure),failure)
        }
        for code in [EACCES,EPERM,EROFS] { XCTAssertEqual(BrowserSetupFailure(POSIXError(.init(rawValue:code)!)),.unwritable) }
        XCTAssertEqual(BrowserSetupFailure(BrowserSetupError.noBrowser),.noBrowser)
        XCTAssertEqual(BrowserSetupFailure(BrowserSetupError.invalidHost),.unsafe)
        XCTAssertEqual(BrowserSetupFailure(BrowserSetupError.unavailable),.temporary)
    }
}

extension XCTestCase {
    /// Observe actual state publication. The deadline only reports a missing event.
    @MainActor func waitForSetupState(_ setup: BackgroundBrowserSetup, _ state: BackgroundBrowserSetup.State) async {
        let event = expectation(description:"Setup state published: \(state)")
        let waiter = SetupStateWaiter(setup,state,event)
        waiter.observe()
        await fulfillment(of:[event],timeout:5)
        withExtendedLifetime(waiter) {}
        XCTAssertEqual(setup.state,state)
    }
}

@MainActor private final class SetupStateWaiter {
    let setup: BackgroundBrowserSetup, state: BackgroundBrowserSetup.State, event: XCTestExpectation
    init(_ setup: BackgroundBrowserSetup, _ state: BackgroundBrowserSetup.State, _ event: XCTestExpectation) {
        self.setup = setup; self.state = state; self.event = event
    }
    func observe() {
        if setup.state == state { event.fulfill(); return }
        withObservationTracking { _ = setup.state } onChange: { [weak self] in
            Task { @MainActor in self?.observe() }
        }
    }
}
