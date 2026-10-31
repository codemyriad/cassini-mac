// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Per-session D33 decisions. The device owner supplies the actual selected
/// source; an attempted fallback/restoration never commits source state here.
public struct BrowserCallLifecycle: Sendable {
    public enum Page: String, Sendable { case present, navigating, closed }
    public enum StopReason: String, Sendable { case callEnded, tabClosed, pageGone }
    public enum Action: Equatable, Sendable { case fallback, restore, stop(StopReason) }
    public static let callEndGrace: TimeInterval = 2
    public static let browserReturnGrace: TimeInterval = 120
    private var missingSince: TimeInterval?
    private var emptySince: TimeInterval?
    private var closedSince: TimeInterval?
    private var previous: TimeInterval?
    private var observedLoss: TimeInterval?
    private var navigationPending = false
    private var stopped = false
    public init() {}

    public mutating func step(now: TimeInterval, page: Page?, sourceCount: Int,
                              sameTab: Bool = true, transportAlive: Bool = true,
                              usingSystem: Bool, others: Bool, restoreReady: Bool = true,
                              pageObservedAt: TimeInterval? = nil, lostAt: TimeInterval? = nil) -> Action? {
        guard !stopped, now.isFinite, now >= 0, previous.map({ now >= $0 }) ?? true else { return nil }
        previous = now
        let page = sameTab ? page : nil
        let count = sameTab ? sourceCount : 0
        if page == .navigating { navigationPending = true }
        func stamp(_ value: TimeInterval?) -> TimeInterval? {
            guard let value, value.isFinite, value >= 0, value <= now else { return nil }; return value
        }
        if page == .closed, closedSince == nil { closedSince = stamp(pageObservedAt) ?? now }
        // Browser-confirmed closure is sticky even if an obsolete page later
        // reports audio. It never starts a new fallback source.
        if let closedSince {
            return now - closedSince >= Self.callEndGrace ? stop(.tabClosed) : nil
        }
        // A delayed first observation must still enforce the producer's loss
        // deadline. A returned page acknowledges each loss only once, even if
        // restoring the selected input fails and the owner retains its stamp.
        if let loss = stamp(lostAt), loss != observedLoss {
            observedLoss = loss; missingSince = min(missingSince ?? loss,loss)
        }
        if missingSince == nil, page != .present || !transportAlive {
            missingSince = page != .present ? stamp(pageObservedAt) ?? now : now
        }
        // This check precedes positive-source recovery, including a return
        // arriving after the deadline before the next timer callback.
        if let missingSince, now - missingSince >= Self.browserReturnGrace { return stop(.pageGone) }
        if page == .present, count > 0, transportAlive {
            missingSince = nil; emptySince = nil; navigationPending = false
            return usingSystem && others && restoreReady ? .restore : nil
        }
        // Returning control can confirm a hangup even if the audio transport
        // is gone. Only a browser-confirmed navigation retains the long grace.
        // Acknowledge this loss so its retained producer stamp cannot restart it.
        if page == .present, count == 0, !navigationPending {
            missingSince = nil
            if emptySince == nil { emptySince = now }
            return now - emptySince! >= Self.callEndGrace ? stop(.callEnded) : nil
        }
        if page != .present || !transportAlive || missingSince != nil {
            emptySince = nil
            if missingSince == nil { missingSince = now }
            return now - missingSince! >= Self.callEndGrace && !usingSystem && others ? .fallback : nil
        }
        if emptySince == nil { emptySince = now }
        return now - emptySince! >= Self.callEndGrace ? stop(.callEnded) : nil
    }
    private mutating func stop(_ reason: StopReason) -> Action {
        stopped = true; return .stop(reason)
    }
}
