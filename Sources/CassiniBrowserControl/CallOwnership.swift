// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import CassiniKit

/// D52.5 lost-call ownership: which browser call each live recording holds, and what follows
/// from it once the recording's audio transport closed.
///
/// The app feeds each recording's binding (its call key and generation, whether it follows the
/// call, whether it is still recording). The audio broker feeds transport loss and resume
/// synchronously, on its own thread, as the EOF or loss Stop is handled. The control service
/// reads `lostCalls` on its queue right before it admits any Start, so a control reconnect
/// never Starts a call whose recording is waiting to be resumed, however late the app's main
/// actor catches up. Pure: every decision here is a function of what was fed.
public struct CallOwnership: Sendable, Equatable {
    public struct Binding: Sendable, Equatable {
        /// The call row the recording is bound to (control peer and tab), when known.
        public var key: BrowserMeetingKey?
        /// The call generation the recording belongs to, once learned (never replaced).
        public var callGeneration: String?
        /// A Chromium capture, or a D49 stand-in whose take-over committed (callConnected).
        public var follows: Bool
        /// Recording and not saving.
        public var recording: Bool
        public init(key: BrowserMeetingKey?, callGeneration: String?, follows: Bool, recording: Bool) {
            self.key = key; self.callGeneration = callGeneration; self.follows = follows; self.recording = recording
        }
    }
    private var bindings: [UUID:Binding] = [:]
    private var lost: Set<UUID> = []
    /// What a recording's own control peer last said about itself, kept across control gaps.
    private struct Known: Sendable, Equatable { var instance: BrowserInstance? }
    private var known: [UUID:Known] = [:]
    public init() {}

    /// One poll's lost-call decisions for a recording (see `follow`).
    public struct Follow: Sendable, Equatable {
        /// The call row the recording is bound to after this poll.
        public var key: BrowserMeetingKey?
        /// The lost recording followed its call to another row this poll: adopt `key`.
        public var rebound = false
        /// The recording's call is over in its tab (D52 M6), also seen from a new control peer.
        public var end: BrowserCallLifecycle.StopReason?
        /// D57 (R78.1): an active session for the tab is still listed.
        public var sessionListed: Bool
        /// The bound call is still reported: its own peer is reconciled and either its row or
        /// an active session for its tab is listed. When the row is gone too, the call has
        /// left: that is missing-page evidence, not unknown inventory (a row with an unknown
        /// count stays visible).
        public var callVisible = false
    }

    /// The app's view of a recording. A learned generation is kept: a later binding without one
    /// (a status that no longer lists the session) never forgets which call this is.
    public mutating func bind(_ id: UUID, _ binding: Binding) {
        var value = binding
        if value.callGeneration == nil { value.callGeneration = bindings[id]?.callGeneration }
        bindings[id] = value
    }
    /// The broker, as it accepts a browser Start: the recording belongs to this call from its
    /// first moment, before any status could tell the app its tab. The generation is the
    /// call's identity (browser-made, unguessable); its tab is the row reporting it.
    /// A binding that exists already (the app was faster) only gains the generation it lacks.
    public mutating func started(_ id: UUID, callGeneration: String) {
        if bindings[id] != nil { if bindings[id]?.callGeneration == nil { bindings[id]?.callGeneration = callGeneration }; return }
        bindings[id] = .init(key:nil,callGeneration:callGeneration,follows:true,recording:true)
    }
    /// The recording ended or was saved; it holds no call.
    public mutating func remove(_ id: UUID) { bindings.removeValue(forKey:id); lost.remove(id); known.removeValue(forKey:id) }
    /// The broker: this recording's audio transport closed (EOF or a loss Stop). The
    /// recording keeps running on its fallback and waits to be resumed.
    public mutating func transportLost(_ id: UUID) { lost.insert(id) }
    /// The broker: a resumed transport attached to this recording.
    public mutating func transportResumed(_ id: UUID) { lost.remove(id) }

    public func binding(_ id: UUID) -> Binding? { bindings[id] }
    public func isLost(_ id: UUID) -> Bool { lost.contains(id) && holds(id) != nil }
    /// A still recording recording that follows a known call (its generation; D51: every
    /// supported extension names one). Its tab may not be known yet.
    private func holds(_ id: UUID) -> Binding? {
        guard let value = bindings[id], value.follows, value.recording, value.callGeneration != nil else { return nil }
        return value
    }
    /// The calls (tab, generation) held by a recording whose transport closed. Each is resumed,
    /// never Started afresh, by auto-record or Record all, on any control peer. A held call
    /// whose tab the recording never learned is found by its generation among `meetings`.
    public func lostCalls(among meetings: [BrowserMeeting] = []) -> Set<BrowserControlRegistry.LostCall> {
        var calls = Set<BrowserControlRegistry.LostCall>()
        for id in lost {
            guard let value = holds(id), let generation = value.callGeneration else { continue }
            if let key = value.key { calls.insert(.init(tabID:key.tabID,callGeneration:generation)) }
            for row in meetings where row.callGeneration == generation { calls.insert(.init(tabID:row.key.tabID,callGeneration:generation)) }
        }
        return calls
    }
    public var lostCalls: Set<BrowserControlRegistry.LostCall> { lostCalls() }
    /// The recording's call (its generation, in its tab when known) among the meetings of every
    /// reconciled control peer, past or present. Only a lost recording follows its call.
    public func call(of id: UUID, among meetings: [BrowserMeeting]) -> BrowserMeetingKey? {
        guard isLost(id), let value = bindings[id], let generation = value.callGeneration else { return nil }
        return meetings.first { $0.callGeneration == generation && (value.key == nil || $0.key.tabID == value.key!.tabID) }?.key
    }
    /// D52 M6: the recording ends as callEnded once its tab's row names another call. It is
    /// judged against the generation the recording learned, so it still applies after the
    /// session left the status (a lost recording), and falls back to the session's own report.
    public func endsForCallChange(_ id: UUID, reported: String?, current: String?) -> BrowserCallLifecycle.StopReason? {
        BrowserCallPolicy.endForCallChange(started:bindings[id]?.callGeneration ?? reported,current:current)
    }
    /// A lost recording holds this call: no other recording (a fresh Start or a D49 stand-in)
    /// may take it; only this recording's own resume.
    /// A still-owned browser route fences signal admission through a control reconnect,
    /// before replacement status can bind the live capture to its new peer.
    func holdsSignal(tab: Int, generation: String?) -> Bool {
        guard let generation else { return false }
        return bindings.values.contains { $0.follows && $0.recording && Data(($0.callGeneration ?? "").utf8) == Data(generation.utf8) && ($0.key == nil || $0.key?.tabID == tab) }
    }
    public func holds(meeting: BrowserMeeting) -> Bool {
        lostCalls(among:[meeting]).contains(.init(tabID:meeting.key.tabID,callGeneration:meeting.callGeneration))
    }
    /// Every per-poll lost-call decision for a recording, from the reconciled control peers:
    /// - a lost recording follows its call (same tab and generation) to whichever peer reports it;
    /// - its own peer's browser instance is remembered across control gaps;
    /// - it ends as callEnded once its tab names another call, judged against the
    ///   generation it learned (else its session's report); after a reconnect, the same
    ///   browser's new peer reporting the tab on another call and not on this one ends it too;
    /// - only an active session (never interrupted history) counts as listed.
    public mutating func follow(_ id: UUID, captureID: String?, peers: [BrowserControlPeerSnapshot]) -> Follow {
        guard var value = bindings[id] else { return .init(key:nil,end:nil,sessionListed:false) }
        let reconciled = peers.filter(\.reconciled)
        var rebound = false
        if isLost(id), let key = call(of:id,among:reconciled.flatMap(\.meetings)), key != value.key {
            value.key = key; bindings[id] = value; rebound = true
        }
        let peer = reconciled.first { $0.id == value.key?.peer }
        if let peer { known[id] = .init(instance:peer.browserInstance ?? known[id]?.instance) }
        let reported = captureID.flatMap { id in
            peer.flatMap { ($0.captures + $0.interrupted).first { $0.captureID.map { Data($0.utf8) == Data(id.utf8) } == true }?.callGeneration }
        }
        var end = BrowserCallPolicy.endForCallChange(started:value.callGeneration ?? reported,current:peer?.meetings.first { $0.key == value.key }?.callGeneration)
        if end == nil, peer == nil, isLost(id), let key = value.key, let generation = value.callGeneration, let instance = known[id]?.instance {
            let rows = reconciled.filter { $0.browserInstance == instance }.flatMap(\.meetings).filter { $0.key.tabID == key.tabID }
            if !rows.contains(where:{ $0.callGeneration == generation }), let other = rows.first(where:{ $0.callGeneration != nil }) {
                end = BrowserCallPolicy.endForCallChange(started:generation,current:other.callGeneration)
            }
        }
        let listed = Self.sessionListed(tabID:value.key?.tabID,peer:peer)
        let visible = peer.map { peer in listed || peer.meetings.contains { $0.key == value.key } } ?? false
        return .init(key:value.key,rebound:rebound,end:end,sessionListed:listed,callVisible:visible)
    }
    /// The page evidence a poll acts on: a closed report wins, else the latest. While the bound
    /// call is not visible (neither its row nor an active session remains), a `present` report
    /// can only be history, such as an interrupted session's last state kept across a worker
    /// restart, and is ignored: it must not keep a recording alive after its call.
    public static func page(_ reports: [(BrowserCallLifecycle.Page,TimeInterval?)], callVisible: Bool) -> (BrowserCallLifecycle.Page,TimeInterval?)? {
        let usable = callVisible ? reports : reports.filter { $0.0 != .present }
        return usable.first { $0.0 == .closed } ?? usable.max { ($0.1 ?? 0) < ($1.1 ?? 0) }
    }
    /// D57 (R78.1): the extension still lists an active session (starting, recording or
    /// stopping) for the tab. Interrupted history from a worker restart is not a session.
    public static func sessionListed(tabID: Int?, peer: BrowserControlPeerSnapshot?) -> Bool {
        guard let tabID, let peer else { return false }
        return peer.captures.contains { $0.key.tabID == tabID }
    }
}

/// The one shared `CallOwnership`, fed from the main actor and the broker, read by the service.
public final class CallOwnershipStore: @unchecked Sendable {
    private let lock = NSLock()
    private var state = CallOwnership()
    public init() {}
    public func update(_ body: (inout CallOwnership) -> Void) { lock.withLock { body(&state) } }
    public var snapshot: CallOwnership { lock.withLock { state } }
    public var lostCalls: Set<BrowserControlRegistry.LostCall> { lock.withLock { state.lostCalls } }
    public func lostCalls(among meetings: [BrowserMeeting]) -> Set<BrowserControlRegistry.LostCall> { lock.withLock { state.lostCalls(among:meetings) } }
    public func follow(_ id: UUID, captureID: String?, peers: [BrowserControlPeerSnapshot]) -> CallOwnership.Follow {
        lock.withLock { state.follow(id,captureID:captureID,peers:peers) }
    }
}

/// A stand-in offer consumes its one takeover only after an actual request is armed.
public struct BrowserStandInAttempt: Sendable {
    public private(set) var pending = false
    public private(set) var attempted = false
    public init() {}
    public mutating func begin() -> Bool {
        guard !pending, !attempted else { return false }
        pending = true; return true
    }
    @discardableResult public mutating func complete(requestID: String?) -> Bool {
        guard pending else { return false }
        pending = false
        guard requestID != nil else { return false }
        attempted = true; return true
    }
}
