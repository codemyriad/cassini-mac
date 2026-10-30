// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
import Foundation
@testable import CassiniBrowserSetup

private actor FakeSetupClock {
    private(set) var delays: [Double] = []
    private var sleepers: [UUID:CheckedContinuation<Void,Error>] = [:]
    private var cancelled: Set<UUID> = []
    var pending: Int { sleepers.count }
    func ready(_ count: Int) -> Bool { delays.count == count && pending == 1 }
    func sleep(_ seconds: Double) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void,Error>) in
                delays.append(seconds)
                if cancelled.remove(id) != nil || Task.isCancelled { continuation.resume(throwing:CancellationError()) }
                else { sleepers[id] = continuation }
            }
        } onCancel: { Task { await self.cancel(id) } }
    }
    private func cancel(_ id: UUID) {
        if let continuation = sleepers.removeValue(forKey:id) { continuation.resume(throwing:CancellationError()) }
        else { cancelled.insert(id) }
    }
    func advance() {
        let current = sleepers; sleepers = [:]
        for continuation in current.values { continuation.resume() }
    }
}
private actor SetupAttempts {
    private(set) var count = 0
    private(set) var offMain = true
    private var failures: [BrowserSetupFailure]
    private var gate: CheckedContinuation<Void,Never>?
    let blocking: Bool
    init(_ failures: [BrowserSetupFailure] = [], blocking: Bool = false) { self.failures = failures; self.blocking = blocking }
    func install() async throws {
        count += 1; offMain = offMain && !Thread.isMainThread
        if blocking { await withCheckedContinuation { gate = $0 } }
        if !failures.isEmpty { throw failures.removeFirst() }
    }
    func release() { gate?.resume(); gate = nil }
}
final class BackgroundSetupTests: XCTestCase {
    @MainActor private func eventually(_ check: () async -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = ContinuousClock.now.advanced(by:.seconds(5))
        while ContinuousClock.now < deadline { if await check() { return }; await Task.yield() }
        XCTFail("Background state did not settle",file:file,line:line)
        throw CancellationError()
    }
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
        try await eventually { await clock.pending == 1 }
        XCTAssertEqual(setup.state,.failed(.temporary))
        await clock.advance()
        try await eventually { await clock.ready(2) }
        await clock.advance()
        try await eventually { setup.state == .waiting }
        let delays = await clock.delays, count = await attempts.count, pending = await clock.pending
        XCTAssertEqual(delays,[5,10]); XCTAssertEqual(count,3); XCTAssertEqual(pending,0)
        let offMain = await attempts.offMain; XCTAssertTrue(offMain)
    }
    @MainActor func testActivationOrRetryResetsBackoffAndCancelsOldTimer() async throws {
        let clock = FakeSetupClock(), attempts = SetupAttempts([.temporary,.temporary,.temporary])
        let setup = BackgroundBrowserSetup(install:{ try await attempts.install() },sleep:{ try await clock.sleep($0) },random:{ 0.5 })
        defer { setup.stop() }
        setup.trigger(); try await eventually { await clock.pending == 1 }
        await clock.advance(); try await eventually { await clock.ready(2) }
        setup.trigger(); try await eventually { await clock.ready(3) }
        let delays = await clock.delays; XCTAssertEqual(delays,[5,10,5])
        await clock.advance(); try await eventually { setup.state == .waiting }
        let count = await attempts.count; XCTAssertEqual(count,4)
    }
    @MainActor func testPermanentFailuresOnlyRetryOnTrigger() async throws {
        for failure: BrowserSetupFailure in [.noBrowser,.unwritable,.unsafe] {
            let clock = FakeSetupClock(), attempts = SetupAttempts([failure])
            let setup = BackgroundBrowserSetup(install:{ try await attempts.install() },sleep:{ try await clock.sleep($0) })
            setup.trigger(); try await eventually { setup.state == .failed(failure) }
            let delays = await clock.delays; XCTAssertEqual(delays,[])
            await clock.advance(); let count = await attempts.count; XCTAssertEqual(count,1)
            setup.trigger(); try await eventually { setup.state == .waiting }; setup.stop()
        }
    }
    @MainActor func testEventsDuringAttemptCoalesceWithoutBlockingUIActor() async throws {
        let attempts = SetupAttempts(blocking:true)
        let setup = BackgroundBrowserSetup(install:{ try await attempts.install() })
        defer { setup.stop() }
        setup.trigger(); try await eventually { await attempts.count == 1 }
        // This code is on the UI actor while the worker is still blocked.
        for _ in 0..<20 { setup.trigger() }
        let count = await attempts.count; XCTAssertEqual(count,1)
        await attempts.release(); try await eventually { await attempts.count == 2 }
        await attempts.release(); try await eventually { setup.state == .waiting }
        let final = await attempts.count, offMain = await attempts.offMain
        XCTAssertEqual(final,2); XCTAssertTrue(offMain)
    }
    @MainActor func testStopCancelsScheduledRetry() async throws {
        let clock = FakeSetupClock(), attempts = SetupAttempts([.temporary])
        let setup = BackgroundBrowserSetup(install:{ try await attempts.install() },sleep:{ try await clock.sleep($0) })
        setup.trigger(); try await eventually { await clock.pending == 1 }
        setup.stop(); try await eventually { await clock.pending == 0 }
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
