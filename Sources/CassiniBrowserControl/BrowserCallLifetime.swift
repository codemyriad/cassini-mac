// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Discovery zero in a reachable meeting is call end, not browser loss. Missing
/// discovery during reload gets the bounded fallback grace instead. The loss
/// stamp belongs to the producer, so delayed observers cannot extend that grace.
public struct BrowserCallLifetime: Sendable {
    private var emptySince: TimeInterval?
    public init() {}
    public mutating func shouldStop(now: TimeInterval, browserAlive: Bool,
                                    lostAt: TimeInterval?, reachable: Bool, sourceCount: Int?) -> Bool {
        guard now.isFinite else { return false }
        if let sourceCount, sourceCount > 0 { emptySince = nil; return false }
        if reachable, sourceCount == 0 {
            if emptySince == nil { emptySince = now }
            return now - emptySince! >= 2
        }
        emptySince = nil
        guard !browserAlive, let lostAt, lostAt.isFinite else { return false }
        return now - lostAt >= 30
    }
}
