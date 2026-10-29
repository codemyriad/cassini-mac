// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
@testable import CassiniBrowserControl

final class BrowserCallLifetimeTests: XCTestCase {
    func testReachableHangupStopsAfterTwoSecondsAndNewActivityCancelsTheDebounce() {
        var policy = BrowserCallLifetime()
        XCTAssertFalse(policy.shouldStop(now:1,browserAlive:true,lostAt:nil,reachable:true,sourceCount:0))
        XCTAssertFalse(policy.shouldStop(now:2.9,browserAlive:true,lostAt:nil,reachable:true,sourceCount:0))
        XCTAssertTrue(policy.shouldStop(now:3,browserAlive:true,lostAt:nil,reachable:true,sourceCount:0))
        XCTAssertFalse(policy.shouldStop(now:4,browserAlive:true,lostAt:nil,reachable:true,sourceCount:1))
        XCTAssertFalse(policy.shouldStop(now:5,browserAlive:true,lostAt:nil,reachable:true,sourceCount:0))
        XCTAssertFalse(policy.shouldStop(now:6,browserAlive:true,lostAt:nil,reachable:true,sourceCount:1))
        XCTAssertFalse(policy.shouldStop(now:8,browserAlive:true,lostAt:nil,reachable:true,sourceCount:0))
    }
    func testReloadUsesOriginalLossStampAndReconciledCallKeepsFallbackAlive() {
        var policy = BrowserCallLifetime()
        XCTAssertFalse(policy.shouldStop(now:10,browserAlive:false,lostAt:5,reachable:false,sourceCount:nil))
        XCTAssertFalse(policy.shouldStop(now:34.9,browserAlive:false,lostAt:5,reachable:true,sourceCount:nil))
        XCTAssertTrue(policy.shouldStop(now:35,browserAlive:false,lostAt:5,reachable:false,sourceCount:nil))
        XCTAssertFalse(policy.shouldStop(now:50,browserAlive:false,lostAt:5,reachable:true,sourceCount:2))
        XCTAssertFalse(policy.shouldStop(now:51,browserAlive:false,lostAt:5,reachable:true,sourceCount:0))
        XCTAssertTrue(policy.shouldStop(now:53,browserAlive:false,lostAt:5,reachable:true,sourceCount:0))
        var lateObserver = BrowserCallLifetime()
        XCTAssertTrue(lateObserver.shouldStop(now:100,browserAlive:false,lostAt:5,reachable:false,sourceCount:nil))
    }
    func testManagementDisconnectAloneDoesNotStopAnAliveAudioPath() {
        var policy = BrowserCallLifetime()
        XCTAssertFalse(policy.shouldStop(now:100,browserAlive:true,lostAt:nil,reachable:false,sourceCount:nil))
        XCTAssertFalse(policy.shouldStop(now:100,browserAlive:false,lostAt:nil,reachable:false,sourceCount:nil))
    }
}
