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
    var pendingTimers: (missing: TimeInterval?, ended: TimeInterval?) { (missingSince,emptySince) }
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

/// D52 M3 multi-stream call policy, used only when the extension advertises
/// multi-stream-v1; the legacy D33 `BrowserCallLifecycle` stays for older peers.
/// After remote audio was heard, a present page with a known zero source count
/// has a 30 s grace. Missing inventory is unknown, never zero. Healthy admitted
/// browser PCM (never the native microphone) is evidence while control is absent.
/// The caller supplies the committed others source; actions are requests only.
public struct BrowserCallPolicy: Sendable {
    public enum Action: Equatable, Sendable { case fallback, restore, callConnected, stop(BrowserCallLifecycle.StopReason) }
    public struct Observation: Sendable {
        /// nil: no page report (unknown).
        public var page: BrowserCallLifecycle.Page?
        public var rowPresent = true
        public var sourceCount: Int?
        public var sourceCountKnown = true
        public var heard = false
        public var controlAlive = true
        /// Admitted browser PCM is flowing on the owned transport.
        public var pcmLive = false
        public init(page: BrowserCallLifecycle.Page?, rowPresent: Bool = true, sourceCount: Int?, sourceCountKnown: Bool = true,
                    heard: Bool = false, controlAlive: Bool = true, pcmLive: Bool = false) {
            self.page = page; self.rowPresent = rowPresent; self.sourceCount = sourceCount; self.sourceCountKnown = sourceCountKnown
            self.heard = heard; self.controlAlive = controlAlive; self.pcmLive = pcmLive
        }
    }
    public static let othersGoneGrace: TimeInterval = 30
    public static let tabClosedGrace: TimeInterval = 2
    public static let browserReturnGrace: TimeInterval = 120
    public static let fallbackGrace: TimeInterval = 2
    private var heard = false, stopped = false
    private var ended: TimeInterval?, closed: TimeInterval?, missing: TimeInterval?
    private var previous: TimeInterval?
    public init() {}

    /// `source`/`reason`: the committed othersSource state. `others`: The others is on.
    public mutating func step(now: TimeInterval, _ o: Observation, source: String?, reason: String?, others: Bool = true, restoreReady: Bool = true) -> Action? {
        guard !stopped, now.isFinite, now >= 0, previous.map({ now >= $0 }) ?? true else { return nil }
        previous = now
        let known = o.rowPresent && o.sourceCountKnown && o.sourceCount != nil
        heard = heard || o.heard
        if o.page == .closed, closed == nil { closed = now }
        if let closed {
            guard now - closed >= Self.tabClosedGrace else { return nil }
            stopped = true; return .stop(.tabClosed)
        }
        if !o.controlAlive && o.pcmLive { missing = nil; ended = nil; return nil }
        if let missing, now - missing >= Self.browserReturnGrace { stopped = true; return .stop(.pageGone) }
        if o.page == .present, o.controlAlive, known, (o.sourceCount ?? 0) > 0 {
            missing = nil; ended = nil
            guard source == "system", heard, others else { return nil }
            // D49 takes over only the initial stand-in; restore only undoes a
            // fallback. An explicit system choice is never switched (D52.3b).
            switch reason {
            case "missing": return .callConnected
            case "lost": return restoreReady ? .restore : nil
            default: return nil
            }
        }
        if o.page != .present || !o.controlAlive || missing != nil {
            ended = nil
            if missing == nil { missing = now }
            return now - missing! >= Self.fallbackGrace && source != "system" && others ? .fallback : nil
        }
        guard known else { ended = nil; return nil }
        if heard {
            if ended == nil { ended = now }
            if now - ended! >= Self.othersGoneGrace { stopped = true; return .stop(.callEnded) }
        }
        return nil
    }
}
