// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
@testable import CassiniRecording
final class DiskBudgetTests: XCTestCase {
    func testConcurrentCaptureRatesAddAndStoppingOneDoesNotResetTheOther() {
        let one = UUID(), two = UUID()
        var rates = CaptureWriteRates()
        _ = rates.observe(bytes:[one:0,two:0],at:0)
        let both = rates.observe(bytes:[one:16000,two:32000],at:2)
        XCTAssertEqual(both.values.reduce(0,+),24000)
        let remaining = rates.observe(bytes:[two:64000],at:4)
        XCTAssertEqual(remaining[two],16000)
        XCTAssertNil(remaining[one])
        let initial = rates.observe(bytes:[one:0,two:96000],at:6,initialRates:[one:8000])
        XCTAssertEqual(initial[one],8000); XCTAssertEqual(initial[two],16000)
    }
    func testReserveAndWarningMinutes() {
        let small = DiskBudget(total: 10_000_000_000, free: (1 << 30) + 60 * 288000 * 9, bytesPerSecond: 288000)
        XCTAssertEqual(small.reserve,1 << 30); XCTAssertEqual(small.minutesLeft,9); XCTAssertFalse(small.shouldStop)
        let large = DiskBudget(total: 200_000_000_000, free: 4_000_000_000, bytesPerSecond: 288000)
        XCTAssertEqual(large.reserve,4_000_000_000); XCTAssertEqual(large.minutesLeft,0); XCTAssertTrue(large.shouldStop)
        XCTAssertTrue(DiskBudget(total: 1, free: 0, bytesPerSecond: 0).shouldStop)
        XCTAssertNil(DiskBudget(total: 100_000_000_000, free: 10_000_000_000, bytesPerSecond: .nan).minutesLeft)
        XCTAssertEqual(DiskBudget(total: UInt64.max, free: UInt64.max, bytesPerSecond: 1e-300).minutesLeft,Int.max)
    }
}
