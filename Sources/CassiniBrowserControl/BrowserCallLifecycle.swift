// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import CassiniKit

/// The page states, end reasons and source actions a browser call's policy speaks in.
/// Only extension 0.2.12+ is supported (D51), so every browser recording follows the
/// D52 `BrowserCallPolicy`; the D33 lifecycle for older peers is gone.
public enum BrowserCallLifecycle {
    public enum Page: String, Sendable { case present, navigating, closed }
    public enum StopReason: String, Sendable { case callEnded, tabClosed, pageGone }
    public enum Action: Equatable, Sendable { case fallback, restore, stop(StopReason) }
}

/// D52 M3 multi-stream call policy (multi-stream-v1).
/// After remote audio was heard, a present page with a known zero source count
/// has a 30 s grace. Missing inventory is unknown, never zero. Healthy admitted
/// browser PCM (never the native microphone) is evidence while control is absent.
/// The caller supplies the committed others source; actions are requests only.
public struct BrowserCallPolicy: Sendable {
    /// `askResume` (D52.5): send one resume-capture-v1 Start for this recording.
    public enum Action: Equatable, Sendable { case fallback, restore, callConnected, askResume, stop(BrowserCallLifecycle.StopReason) }
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
        /// D52.5: the row's call generation, and the control connection it arrived on
        /// (it changes only with a new hello).
        public var callGeneration: String?
        public var controlConnection: String = ""
        /// Producer stamps (uptime): when the page state was observed, and when the owner
        /// lost the browser source. A delayed poll still honours their deadlines.
        public var pageObservedAt: TimeInterval?
        public var lostAt: TimeInterval?
        /// D57 (R78.1): the extension's status still lists a session for this tab. The app asks
        /// to resume only once it no longer does.
        public var sessionListed = false
        public init(page: BrowserCallLifecycle.Page?, rowPresent: Bool = true, sourceCount: Int?, sourceCountKnown: Bool = true,
                    heard: Bool = false, controlAlive: Bool = true, pcmLive: Bool = false, transportAlive: Bool = true,
                    callGeneration: String? = nil, controlConnection: String = "",
                    pageObservedAt: TimeInterval? = nil, lostAt: TimeInterval? = nil) {
            self.page = page; self.rowPresent = rowPresent; self.sourceCount = sourceCount; self.sourceCountKnown = sourceCountKnown
            self.heard = heard; self.controlAlive = controlAlive; self.pcmLive = pcmLive; self.transportAlive = transportAlive
            self.callGeneration = callGeneration; self.controlConnection = controlConnection
            self.pageObservedAt = pageObservedAt; self.lostAt = lostAt
        }
    }
    public static let othersGoneGrace: TimeInterval = 30
    public static let tabClosedGrace: TimeInterval = 2
    public static let browserReturnGrace: TimeInterval = 120
    public static let fallbackGrace: TimeInterval = 2
    /// D52.5: the peer negotiated resume-capture-v1, and the recording's call generation.
    /// heard latches only on rows of that generation (any generation while it is nil).
    public var resumeCapture: Bool
    public var callGeneration: String?
    private var heard: Bool, stopped = false
    private var ended: TimeInterval?, closed: TimeInterval?, missing: TimeInterval?
    private var previous: TimeInterval?, observedLoss: TimeInterval?
    /// The control connection this loss's resume was asked on (nil: not asked yet).
    private var askedOn: String?
    /// The control connection of a resume ask that `decide` holds until the fallback commits.
    private var heldAsk: String?
    public init(resumeCapture: Bool = false, callGeneration: String? = nil, heard: Bool = false) {
        self.resumeCapture = resumeCapture; self.callGeneration = callGeneration; self.heard = heard
    }

    /// D49: a native stand-in that asked a call to resume it stays a plain native recording
    /// until the take-over commits (othersSource callConnected). While it is pending, browser
    /// loss, fallback, policy stops and call-change termination do not apply to it; once the
    /// call has taken over, it is handled like any browser recording.
    public static func standInPending(source: String, keyed: Bool, events: [CaptureEvent]) -> Bool {
        source == "macos" && keyed && !events.contains { $0.type == "othersSource" && $0.reason == "callConnected" }
    }
    /// D52.5: the recording is a browser call's own: a Chromium capture, or a D49 stand-in
    /// whose take-over committed (callConnected). A stand-in still pending is native.
    public static func followsCall(source: String, keyed: Bool, events: [CaptureEvent]) -> Bool {
        source == "chromium" || source == "macos" && keyed && !standInPending(source:source,keyed:keyed,events:events)
    }
    /// One poll's source action for a browser recording or a stand-in (D49, D52 M3).
    /// While a stand-in's take-over is pending only the take-over applies: the recording's
    /// policy is not stepped, so no grace, return deadline or terminal state is consumed
    /// before the call joins (a control loss cannot end it as pageGone, and an expired grace
    /// cannot block callConnected). The take-over is judged by a fresh policy seeing this
    /// observation.
    public static func decide(pending: Bool, policy: inout BrowserCallPolicy, now: TimeInterval, _ o: Observation,
                              source: String?, reason: String?, others: Bool, restoreReady: Bool,
                              onAskResume: () -> Void = {}) -> BrowserCallLifecycle.Action? {
        if pending {
            var fresh = BrowserCallPolicy()
            let joins = fresh.step(now:now,o,source:source,reason:reason,others:others,restoreReady:restoreReady) == .callConnected
            return joins && restoreReady ? .restore : nil
        }
        // D52.5: a step can ask to resume as well as act; the ask goes to `onAskResume`.
        let actions = policy.steps(now:now,o,source:source,reason:reason,others:others,restoreReady:restoreReady)
        // The policy asks in the step that falls back (shared vectors), but the host can only
        // join a committed system/lost fallback, which commits with the fallback's first
        // admitted PCM. A resume sent while the fallback is still starting (none/lost) is
        // refused and spends the connection's only attempt, so the ask is held here and sent
        // on the first poll that sees system/lost, while it still applies to that connection.
        // `steps` has marked the connection asked, so a held ask is never dropped for a passing
        // condition (a zero count, a missing row, a listed session): it waits for a poll on
        // which the policy's own ask conditions hold again. Only a new connection, a live
        // transport, Others off or a Stop end it.
        if actions.contains(.askResume) { policy.heldAsk = o.controlConnection }
        if let held = policy.heldAsk {
            let stopped = actions.contains { if case .stop = $0 { return true }; return false }
            if held != o.controlConnection || o.transportAlive || !others || stopped { policy.heldAsk = nil }
            else if source == "system", reason == "lost", policy.mayAsk(o,others:others) { policy.heldAsk = nil; onAskResume() }
        }
        switch primary(actions) {
        case .fallback?: return .fallback
        case .restore?: return .restore
        case .stop(let reason)?: return .stop(reason)
        // D49: the resumed browser PCM commits callConnected through the restore checkpoint.
        case .callConnected?: return restoreReady ? .restore : nil
        case .askResume?, nil: return nil
        }
    }
    /// D52.5: the conditions under which an observation can carry the resume ask, apart from
    /// the committed source and the once-per-connection latch. Shared by `steps` and `decide`.
    func mayAsk(_ o: Observation, others: Bool) -> Bool {
        let known = o.rowPresent && o.sourceCountKnown && o.sourceCount != nil
        return resumeCapture && o.page == .present && o.controlAlive && known && (o.sourceCount ?? 0) > 0 && !o.transportAlive &&
            others && !o.sessionListed && o.callGeneration == callGeneration && heard
    }
    /// When the current browser loss began (the producer's stamp when known), while one is pending.
    public var missingSince: TimeInterval? { missing }
    /// Whether a poll commits the browser source loss before any fallback. A present page with
    /// zero sources is a possible rejoin (D52), but once the policy asks to fall back while the
    /// source is still alive, the loss is committed first: a navigation loss cancelled by the
    /// next page report would otherwise leave the fallback a no-op (the system input starts
    /// only after a committed loss).
    public static func commitsLoss(browserAlive: Bool, page: BrowserCallLifecycle.Page?, navigation: Bool, fallback: Bool) -> Bool {
        navigation || browserAlive && (page != .present || fallback)
    }

    /// D52 M6: a capture belongs to the call it started in. Once the tab's row names another
    /// call generation, the session ends as callEnded instead of absorbing the new call.
    /// An unknown generation on either side is no evidence of a change.
    public static func endForCallChange(started: String?, current: String?) -> BrowserCallLifecycle.StopReason? {
        guard let started, let current, Data(started.utf8) != Data(current.utf8) else { return nil }
        return .callEnded
    }

    /// The action a step's caller applies. A terminal Stop wins over a fallback returned
    /// with it: `steps` has already stopped the policy, so a dropped Stop would never recur
    /// and the recording would run on until stopped by hand. Otherwise the first action that
    /// is not the resume ask.
    public static func primary(_ actions: [Action]) -> Action? {
        actions.first { if case .stop = $0 { return true }; return false } ?? actions.first { $0 != .askResume }
    }
    /// The primary action of `steps`, for callers that never ask to resume.
    public mutating func step(now: TimeInterval, _ o: Observation, source: String?, reason: String?, others: Bool = true, restoreReady: Bool = true) -> Action? {
        Self.primary(steps(now:now,o,source:source,reason:reason,others:others,restoreReady:restoreReady))
    }
    /// `source`/`reason`: the committed othersSource state. `others`: The others is on.
    /// A step can return a fallback and the resume ask together (D52.5).
    public mutating func steps(now: TimeInterval, _ o: Observation, source: String?, reason: String?, others: Bool = true, restoreReady: Bool = true) -> [Action] {
        guard !stopped, now.isFinite, now >= 0, previous.map({ now >= $0 }) ?? true else { return [] }
        previous = now
        let known = o.rowPresent && o.sourceCountKnown && o.sourceCount != nil
        // D52.5: another call's heard never arms this recording's restore, grace or resume ask.
        heard = heard || (o.heard && (callGeneration == nil || callGeneration == o.callGeneration))
        // A committed browser source ends any loss (and its ask) however it came back.
        if source != "system" { askedOn = nil }
        func stamp(_ value: TimeInterval?) -> TimeInterval? {
            guard let value, value.isFinite, value >= 0, value <= now else { return nil }; return value
        }
        if o.page == .closed, closed == nil { closed = stamp(o.pageObservedAt) ?? now }
        if let closed {
            guard now - closed >= Self.tabClosedGrace else { return [] }
            stopped = true; return [.stop(.tabClosed)]
        }
        // Each producer loss is seeded once, so a present page that acknowledged it
        // cannot restart its deadline while the owner retains the stamp.
        if let loss = stamp(o.lostAt), loss != observedLoss { observedLoss = loss; missing = min(missing ?? loss,loss) }
        if missing == nil, o.page == .navigating, let at = stamp(o.pageObservedAt) { missing = at }
        if !o.controlAlive && o.pcmLive && o.transportAlive { missing = nil; ended = nil; return [] }
        // This precedes positive-source recovery: a page that returns after the deadline,
        // first seen by a delayed poll, stops as pageGone.
        if let missing, now - missing >= Self.browserReturnGrace { stopped = true; return [.stop(.pageGone)] }
        // D52.4 Q3: a closed audio transport falls back at once, whatever the page state
        // or count. The rest of this step sees the fallback as committed.
        var actions: [Action] = [], source = source, reason = reason
        if !o.transportAlive, source != "system", others { actions = [.fallback]; source = "system"; reason = "lost"; askedOn = nil }
        if o.page == .present, o.controlAlive, known, (o.sourceCount ?? 0) > 0 {
            // A visibly ongoing call stays on fallback without a pageGone deadline;
            // restoring needs a live audio transport.
            missing = nil; ended = nil
            if o.transportAlive, actions.isEmpty, source == "system", heard, others {
                // D49 takes over only the initial stand-in; restore only undoes a
                // fallback. An explicit system choice is never switched (D52.3b).
                switch reason {
                case "missing": askedOn = nil; return [.callConnected]
                case "lost": if restoreReady { askedOn = nil; return [.restore] }; return []
                default: return []
                }
            }
            // A loss whose fallback has not committed yet (none/lost: the system input is still
            // starting, or waits on the OS permission prompt) is undone too, heard or not: the
            // return cancels that fallback, so without a restore the Others would record nothing.
            if o.transportAlive, actions.isEmpty, source == "none", reason == "lost", others {
                if restoreReady { askedOn = nil; return [.restore] }; return []
            }
            // D52.5: ask once per loss and control connection; never on a timer or later tick.
            if source == "system", reason == "lost", mayAsk(o,others:others), askedOn != o.controlConnection {
                askedOn = o.controlConnection
                return actions + [.askResume]
            }
            return actions
        }
        if o.page != .present || !o.controlAlive || missing != nil {
            ended = nil
            if missing == nil { missing = now }
            if actions.isEmpty, now - missing! >= Self.fallbackGrace, source != "system", others { askedOn = nil; return [.fallback] }
            return actions
        }
        guard known else { ended = nil; return actions }
        if heard {
            if ended == nil { ended = now }
            if now - ended! >= Self.othersGoneGrace { stopped = true; return actions + [.stop(.callEnded)] }
        }
        return actions
    }
}
