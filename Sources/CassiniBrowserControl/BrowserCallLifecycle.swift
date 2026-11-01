// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import CassiniKit

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
        /// D52.4: false once the recording's audio transport closed (EOF, error or the
        /// PCM_STALE_AFTER watchdog). It is not missing-page evidence by itself.
        public var transportAlive = true
        /// Producer stamps (uptime): when the page state was observed, and when the owner
        /// lost the browser source. A delayed poll still honours their deadlines.
        public var pageObservedAt: TimeInterval?
        public var lostAt: TimeInterval?
        public init(page: BrowserCallLifecycle.Page?, rowPresent: Bool = true, sourceCount: Int?, sourceCountKnown: Bool = true,
                    heard: Bool = false, controlAlive: Bool = true, pcmLive: Bool = false, transportAlive: Bool = true,
                    pageObservedAt: TimeInterval? = nil, lostAt: TimeInterval? = nil) {
            self.page = page; self.rowPresent = rowPresent; self.sourceCount = sourceCount; self.sourceCountKnown = sourceCountKnown
            self.heard = heard; self.controlAlive = controlAlive; self.pcmLive = pcmLive; self.transportAlive = transportAlive
            self.pageObservedAt = pageObservedAt; self.lostAt = lostAt
        }
    }
    public static let othersGoneGrace: TimeInterval = 30
    public static let tabClosedGrace: TimeInterval = 2
    public static let browserReturnGrace: TimeInterval = 120
    public static let fallbackGrace: TimeInterval = 2
    private var heard = false, stopped = false
    private var ended: TimeInterval?, closed: TimeInterval?, missing: TimeInterval?
    private var previous: TimeInterval?, observedLoss: TimeInterval?
    public init() {}

    /// D49: a native stand-in that asked a call to resume it stays a plain native recording
    /// until the take-over commits (othersSource callConnected). While it is pending, browser
    /// loss, fallback, policy stops and call-change termination do not apply to it; once the
    /// call has taken over, it is handled like any browser recording.
    public static func standInPending(source: String, keyed: Bool, events: [CaptureEvent]) -> Bool {
        source == "macos" && keyed && !events.contains { $0.type == "othersSource" && $0.reason == "callConnected" }
    }
    /// One poll's source action for a browser recording or a stand-in (D49, D52 M3, D33).
    /// While a stand-in's take-over is pending only the take-over applies: neither the
    /// recording's policy nor its legacy lifecycle is stepped, so no grace, return deadline or
    /// terminal state is consumed before the call joins (a control loss cannot end it as
    /// pageGone, and an expired grace cannot block callConnected). The take-over is judged by
    /// a fresh policy seeing this observation. `legacy` steps the D33 lifecycle.
    public static func decide(pending: Bool, multiStream: Bool, policy: inout BrowserCallPolicy, now: TimeInterval, _ o: Observation,
                              source: String?, reason: String?, others: Bool, restoreReady: Bool,
                              legacy: () -> BrowserCallLifecycle.Action?) -> BrowserCallLifecycle.Action? {
        if pending {
            guard multiStream else { return nil }
            var fresh = BrowserCallPolicy()
            let joins = fresh.step(now:now,o,source:source,reason:reason,others:others,restoreReady:restoreReady) == .callConnected
            return joins && restoreReady ? .restore : nil
        }
        guard multiStream else { return legacy() }
        switch policy.step(now:now,o,source:source,reason:reason,others:others,restoreReady:restoreReady) {
        case .fallback?: return .fallback
        case .restore?: return .restore
        case .stop(let reason)?: return .stop(reason)
        // D49: the resumed browser PCM commits callConnected through the restore checkpoint.
        case .callConnected?: return restoreReady ? .restore : nil
        case nil: return nil
        }
    }
    /// When the current browser loss began (the producer's stamp when known), while one is pending.
    public var missingSince: TimeInterval? { missing }
    /// Whether a poll commits the browser source loss before any fallback. A legacy peer's
    /// present page with zero sources is a loss. Under D52 it is a possible rejoin, but once the
    /// policy asks to fall back while the source is still alive, the loss is committed first:
    /// a navigation loss cancelled by the next page report would otherwise leave the fallback
    /// a no-op (the system input starts only after a committed loss).
    public static func commitsLoss(browserAlive: Bool, page: BrowserCallLifecycle.Page?, count: Int?, multiStream: Bool,
                                   navigation: Bool, fallback: Bool) -> Bool {
        navigation || browserAlive && (page != .present || (!multiStream && count == 0) || (multiStream && fallback))
    }

    /// D52 M6: a capture belongs to the call it started in. Once the tab's row names another
    /// call generation, the session ends as callEnded instead of absorbing the new call.
    /// An unknown generation on either side is no evidence of a change.
    public static func endForCallChange(started: String?, current: String?) -> BrowserCallLifecycle.StopReason? {
        guard let started, let current, Data(started.utf8) != Data(current.utf8) else { return nil }
        return .callEnded
    }

    /// `source`/`reason`: the committed othersSource state. `others`: The others is on.
    public mutating func step(now: TimeInterval, _ o: Observation, source: String?, reason: String?, others: Bool = true, restoreReady: Bool = true) -> Action? {
        guard !stopped, now.isFinite, now >= 0, previous.map({ now >= $0 }) ?? true else { return nil }
        previous = now
        let known = o.rowPresent && o.sourceCountKnown && o.sourceCount != nil
        heard = heard || o.heard
        func stamp(_ value: TimeInterval?) -> TimeInterval? {
            guard let value, value.isFinite, value >= 0, value <= now else { return nil }; return value
        }
        if o.page == .closed, closed == nil { closed = stamp(o.pageObservedAt) ?? now }
        if let closed {
            guard now - closed >= Self.tabClosedGrace else { return nil }
            stopped = true; return .stop(.tabClosed)
        }
        // Each producer loss is seeded once, so a present page that acknowledged it
        // cannot restart its deadline while the owner retains the stamp.
        if let loss = stamp(o.lostAt), loss != observedLoss { observedLoss = loss; missing = min(missing ?? loss,loss) }
        if missing == nil, o.page == .navigating, let at = stamp(o.pageObservedAt) { missing = at }
        if !o.controlAlive && o.pcmLive && o.transportAlive { missing = nil; ended = nil; return nil }
        // This precedes positive-source recovery: a page that returns after the deadline,
        // first seen by a delayed poll, stops as pageGone.
        if let missing, now - missing >= Self.browserReturnGrace { stopped = true; return .stop(.pageGone) }
        // D52.4 Q3: a closed audio transport falls back at once, whatever the page state
        // or count. The rest of this step sees the fallback as committed.
        var action: Action?, source = source
        if !o.transportAlive, source != "system", others { action = .fallback; source = "system" }
        if o.page == .present, o.controlAlive, known, (o.sourceCount ?? 0) > 0 {
            // A visibly ongoing call stays on fallback without a pageGone deadline;
            // restoring needs a live audio transport.
            missing = nil; ended = nil
            guard o.transportAlive, action == nil, source == "system", heard, others else { return action }
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
            return action ?? (now - missing! >= Self.fallbackGrace && source != "system" && others ? .fallback : nil)
        }
        guard known else { ended = nil; return action }
        if heard {
            if ended == nil { ended = now }
            if now - ended! >= Self.othersGoneGrace { stopped = true; return .stop(.callEnded) }
        }
        return action
    }
}
