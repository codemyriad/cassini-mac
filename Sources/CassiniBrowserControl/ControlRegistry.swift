// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import CassiniKit

public struct BrowserMeetingKey: Hashable, Sendable {
    /// Origin of this UI identity, which may be a released connection.
    public let peer: UUID
    public let tabID: Int
    public init(peer: UUID, tabID: Int) { self.peer = peer; self.tabID = tabID }
}
public struct BrowserMeeting: Equatable, Sendable {
    public let key: BrowserMeetingKey
    public let title: String
    public let url: String
    public let sourceCount: Int
    public let heard: Bool
}
/// Reported paths are advisory status, never filesystem destinations or grants.
public struct BrowserCaptureStatus: Equatable, Sendable {
    public let key: BrowserMeetingKey
    public let captureID: String?
    public let path: String?
    public let recording: Bool
    public let stopping: Bool
    public let tracks: Int
}
public struct BrowserControlPeerSnapshot: Sendable {
    /// Current physical connection; meeting keys can retain an older origin.
    public let id: UUID
    public let browser: String?
    public let browserInstance: BrowserInstance?
    public let reconciled: Bool
    public let independent: Bool
    public let meetings: [BrowserMeeting]
    public let captures: [BrowserCaptureStatus]
    public let interrupted: [BrowserCaptureStatus]
}
public enum BrowserControlAction: String, Sendable { case start, stop }
public struct BrowserControlRequest: Sendable {
    public let id: String
    public let key: BrowserMeetingKey
    /// Physical transport owner. A meeting key can outlive this connection.
    public let connectionID: UUID
    public let action: BrowserControlAction
    public let data: Data
}
public struct BrowserControlOutcome: Equatable, Sendable {
    public let requestID: String
    public let key: BrowserMeetingKey
    public let action: BrowserControlAction
    public let ok: Bool
    public let error: String?
}
public enum BrowserControlStateError: Error { case unavailable, notReconciled, incompatible, noSources, busy, malformed, limit }

/// Value-only control state. A driver serializes access; audio writers never run
/// here. Control loss removes discovery/pending requests, not audio recordings.
public struct BrowserControlRegistry: Sendable {
    private struct Pending: Sendable {
        let request: BrowserControlRequest
        let statusRevision: UInt64
        let order: UInt64
        let stopCaptureID: String?
        let url: String?
    }
    private struct PeerState: Sendable {
        let peer: BrowserPeer
        var hello = false, independent = false, callEvidence = false, reconciled = false
        var statusRevision: UInt64 = 0
        var commandOrder: UInt64 = 0, lastResultOrder: UInt64 = 0
        var meetings: [BrowserMeeting] = []
        var captures: [BrowserCaptureStatus] = []
        var interrupted: [BrowserCaptureStatus] = []
        var pending: [String:Pending] = [:]
        var autoAttempted: Set<Int> = []
        var requestedStops: Set<Int> = []
        var connectedAt: TimeInterval = 0
        var connectionOrder: UInt64 = 0
        var superseded = false
        var keys: [Int:BrowserMeetingKey] = [:]
    }
    private struct Released: Sendable {
        var peer: PeerState
        let until: TimeInterval
    }
    private var released: [UUID:Released] = [:]
    private struct CallContext: Sendable { let call: BrowserCallIdentity; var touched: TimeInterval }
    private var stoppedCalls = UserStoppedCalls()
    private var knownCalls: [BrowserMeetingKey:CallContext] = [:]
    private var captureCalls: [Data:CallContext] = [:]
    private let clock: @Sendable () -> TimeInterval
    private let instanceAlive: @Sendable (BrowserInstance) -> Bool?
    private var connectionOrder: UInt64 = 0
    private var peers: [UUID:PeerState] = [:]
    private var retainedCaptureIDs: Set<Data> = []
    public private(set) var outcomes: [BrowserControlOutcome] = []
    private var deliveries: [BrowserControlOutcome] = []
    /// The driver drains after each mutation. History is capped separately so
    /// expiring several profiles together cannot lose a pending completion.
    public mutating func takeOutcomes() -> [BrowserControlOutcome] {
        let result = deliveries; deliveries.removeAll(keepingCapacity:true); return result
    }
    public init(clock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                instanceAlive: @escaping @Sendable (BrowserInstance) -> Bool? = { $0.isAlive }) {
        self.clock = clock; self.instanceAlive = instanceAlive
    }
    var rememberedStopCount: Int { stoppedCalls.count }
    private func call(_ meeting: BrowserMeeting, peer: PeerState) -> BrowserCallIdentity? {
        peer.peer.browserInstance.map { .init(instance:$0,tabID:meeting.key.tabID,url:meeting.url) }
    }
    private func newestOwner(_ peer: PeerState, tab: Int) -> Bool {
        guard !peer.superseded else { return false }
        guard let instance = peer.peer.browserInstance else { return true }
        return !peers.values.contains { other in
            other.peer.browserInstance == instance && other.connectionOrder > peer.connectionOrder &&
                other.meetings.contains(where:{ $0.key.tabID == tab })
        }
    }
    /// Runs before replacing inventories, including the first inventory after
    /// reconnect. Only the old live inventory can protect an otherwise old Stop.
    public mutating func expireRememberedStops() {
        let now = clock()
        for id in Array(released.keys) {
            guard let old = released[id], old.until <= now || old.peer.peer.browserInstance.map({ instanceAlive($0) == false }) == true else { continue }
            for pending in old.peer.pending.values {
                appendOutcome(.init(requestID:pending.request.id,key:pending.request.key,action:pending.request.action,ok:false,error:nil))
            }
            released.removeValue(forKey:id)
        }
        let live = Set(peers.values.flatMap { peer in peer.meetings.filter { newestOwner(peer,tab:$0.key.tabID) }.compactMap { call($0,peer:peer) } })
        stoppedCalls.expire(now:now,priorLive:live,alive:instanceAlive)
        knownCalls = knownCalls.filter { now-$0.value.touched < UserStoppedCalls.retention || live.contains($0.value.call) }
        captureCalls = captureCalls.filter { retainedCaptureIDs.contains($0.key) || now-$0.value.touched < UserStoppedCalls.retention }
        for id in retainedCaptureIDs {
            if var context = captureCalls[id] { context.touched = now; captureCalls[id] = context }
        }
    }
    private mutating func rememberContext(_ context: CallContext, key: BrowserMeetingKey) {
        knownCalls[key] = context
        if knownCalls.count > UserStoppedCalls.limit, let oldest = knownCalls.min(by:{ $0.value.touched < $1.value.touched })?.key {
            knownCalls.removeValue(forKey:oldest)
        }
    }
    private mutating func bindCaptures(_ peer: PeerState) {
        for capture in peer.captures + peer.interrupted {
            guard let id = capture.captureID.map({ Data($0.utf8) }) else { continue }
            if var original = captureCalls[id] { original.touched = clock(); captureCalls[id] = original; continue }
            let requestedURL = peer.pending.values.first { $0.request.action == .start && $0.request.key == capture.key }?.url
            if let instance = peer.peer.browserInstance,
               let url = requestedURL ?? peer.meetings.first(where:{ $0.key == capture.key })?.url {
                bind(id,to:.init(call:.init(instance:instance,tabID:capture.key.tabID,url:url),touched:clock()))
            }
        }
    }
    private mutating func bind(_ id: Data, to context: CallContext) {
        guard captureCalls[id] == nil else { return }
        captureCalls[id] = context
        if captureCalls.count > UserStoppedCalls.limit {
            let candidates = captureCalls.filter { !retainedCaptureIDs.contains($0.key) }
            if let oldest = (candidates.isEmpty ? captureCalls : candidates).min(by:{ $0.value.touched < $1.value.touched })?.key {
                captureCalls.removeValue(forKey:oldest)
            }
        }
    }
    /// Capture IDs bind to their original address as soon as status reports
    /// them, even before the audio peer/owned folder has registered.
    public mutating func rememberUserStop(key: BrowserMeetingKey? = nil, captureID: String? = nil) {
        expireRememberedStops()
        let context: CallContext?
        if let captureID { context = captureCalls[Data(captureID.utf8)] }
        else { context = key.flatMap { knownCalls[$0] } }
        if let context { stoppedCalls.remember(context.call,now:clock()) }
    }
    public var snapshots: [BrowserControlPeerSnapshot] {
        let active = peers.values.filter { !$0.superseded }
        let liveKeys = Set(active.flatMap { $0.meetings.map(\.key) })
        let waiting = released.values.map(\.peer).filter { !$0.superseded }.compactMap { old -> PeerState? in
            var copy = old; copy.meetings.removeAll { liveKeys.contains($0.key) }
            return copy.meetings.isEmpty ? nil : copy
        }
        return (Array(active) + waiting).sorted { $0.peer.id.uuidString < $1.peer.id.uuidString }.map {
            .init(id:$0.peer.id,browser:$0.peer.browser,browserInstance:$0.peer.browserInstance,reconciled:$0.reconciled,independent:$0.independent,meetings:$0.meetings,captures:$0.captures,interrupted:$0.interrupted)
        }
    }
    public mutating func setRetainedCaptureIDs(_ ids: [String]) {
        retainedCaptureIDs = Set(ids.map { Data($0.utf8) })
        for id in Array(peers.keys) {
            guard var peer = peers[id] else { continue }
            // A recovered tab whose app-owned folder is on system fallback is
            // already covered. Stop must not immediately auto-restart that call.
            peer.autoAttempted.formUnion(peer.interrupted.filter { Self.retained($0,ids:retainedCaptureIDs) }.map { $0.key.tabID })
            peers[id] = peer
        }
    }
    private static func retained(_ capture: BrowserCaptureStatus, ids: Set<Data>) -> Bool {
        capture.captureID.map { ids.contains(Data($0.utf8)) } ?? false
    }
    public mutating func connect(_ peer: BrowserPeer) throws {
        expireRememberedStops()
        guard peer.role == .control, peers[peer.id] == nil, peers.count < 128 else { throw BrowserControlStateError.unavailable }
        connectionOrder &+= 1
        peers[peer.id] = PeerState(peer:peer,connectedAt:clock(),connectionOrder:connectionOrder)
    }
    public mutating func disconnect(_ id: UUID) {
        expireRememberedStops()
        guard let peer = peers.removeValue(forKey:id) else { return }
        var old = peer
        old.reconciled = false; old.captures = []; old.interrupted = []
        old.autoAttempted = []; old.requestedStops = []
        old.pending = peer.pending.filter { $0.value.request.action == .start }
        if peer.peer.browserInstance != nil {
            // Keep UI choices and uncertain Starts briefly, never replay them.
            if released.count >= 128, let oldest = released.min(by:{ $0.value.until < $1.value.until })?.key {
                retireReleased(oldest)
            }
            released[id] = .init(peer:old,until:clock()+10)
        }
        for pending in peer.pending.values where peer.peer.browserInstance == nil || pending.request.action != .start {
            appendOutcome(.init(requestID:pending.request.id,key:pending.request.key,action:pending.request.action,ok:false,error:nil))
        }
    }
    private mutating func retireReleased(_ id: UUID) {
        guard let old = released.removeValue(forKey:id) else { return }
        for pending in old.peer.pending.values {
            appendOutcome(.init(requestID:pending.request.id,key:pending.request.key,action:pending.request.action,ok:false,error:nil))
        }
    }
    public mutating func finishReconnects() {
        for id in Array(released.keys) { retireReleased(id) }
    }
    /// Per-tab aliases are assigned once. Late overlap must not re-key a new
    /// tab whose command was already issued while the worker rebuilt its list.
    private mutating func assignKeys(_ tabs: Set<Int>, peer: inout PeerState) {
        let candidates = Array(peers.values) + released.values.map(\.peer)
        for tab in tabs where peer.keys[tab] == nil {
            let prior = peer.peer.browserInstance.flatMap { instance in
                candidates.filter { $0.peer.id != peer.peer.id && $0.peer.browserInstance == instance && $0.connectionOrder < peer.connectionOrder }
                    .sorted { $0.connectionOrder > $1.connectionOrder }
                    .first { $0.keys[tab] != nil }
            }
            peer.keys[tab] = prior?.keys[tab] ?? .init(peer:peer.peer.id,tabID:tab)
        }
        if peer.keys.count > 512 {
            let needed = tabs.union(peer.meetings.map { $0.key.tabID }).union((peer.captures+peer.interrupted).map { $0.key.tabID }).union(peer.pending.values.map { $0.request.key.tabID })
            peer.keys = peer.keys.filter { needed.contains($0.key) }
        }
    }
    private func uncertainStart(_ key: BrowserMeetingKey, url: String? = nil) -> Bool {
        (Array(peers.values) + released.values.map(\.peer)).contains { state in
            state.pending.values.contains { pending in
                pending.request.action == .start && pending.request.key == key &&
                    (url.map { target in pending.url.map { Data($0.utf8) == Data(target.utf8) } == true } ?? true)
            }
        }
    }
    private func owner(_ key: BrowserMeetingKey) -> UUID? {
        peers.values.filter { !$0.superseded && ($0.keys[key.tabID] == key || $0.peer.id == key.peer) }
            .max { $0.connectionOrder < $1.connectionOrder }?.peer.id
    }
    private func remap(_ captures: [BrowserCaptureStatus], peer: PeerState) -> [BrowserCaptureStatus] {
        captures.map { .init(key:peer.keys[$0.key.tabID] ?? $0.key,captureID:$0.captureID,path:$0.path,recording:$0.recording,stopping:$0.stopping,tracks:$0.tracks) }
    }
    private mutating func resolveReturningStarts(_ peer: PeerState) {
        guard peer.reconciled, !peer.superseded, let instance = peer.peer.browserInstance else { return }
        for id in Array(released.keys) {
            guard var old = released[id], old.peer.peer.browserInstance == instance else { continue }
            for (requestID,pending) in old.peer.pending {
                guard newestOwner(peer,tab:pending.request.key.tabID),
                      let meeting = peer.meetings.first(where:{ $0.key == pending.request.key }),
                      pending.url.map({ Data($0.utf8) == Data(meeting.url.utf8) }) == true,
                      peer.captures.contains(where:{ $0.key == meeting.key && $0.captureID != nil }) else { continue }
                old.peer.pending.removeValue(forKey:requestID)
                appendOutcome(.init(requestID:requestID,key:pending.request.key,action:.start,ok:true,error:nil))
            }
            released[id] = old
        }
    }
    public mutating func receive(_ bytes: Data, from id: UUID) throws {
        let json = try JSONParser.parse(FrameIO.normalized(bytes))
        guard var peer = peers[id], let type = json["type"]?.string else { throw BrowserControlStateError.malformed }
        expireRememberedStops()
        switch type {
        case "hello":
            guard !peer.hello, json["version"]?.int == 1 else { throw BrowserControlStateError.malformed }
            if let raw = json["capabilities"], !raw.isNull {
                guard let values = raw.array, values.allSatisfy({ $0.string != nil }) else { throw BrowserControlStateError.malformed }
                peer.independent = values.contains { $0.string == "independent-sessions-v1" }
                peer.callEvidence = values.contains { $0.string == "call-evidence-v1" }
            }
            peer.hello = true
        case "meetings":
            guard peer.hello, let values = json["meetings"]?.array, values.count <= 100 else { throw BrowserControlStateError.malformed }
            var found = Set<Int>()
            let parsed = try values.map { value -> BrowserMeeting in
                let tab = try Self.integer(value["tabId"])
                let title = try Self.string(value["title"],maximum:200)
                let url = try Self.string(value["url"],maximum:2048)
                guard let parts = URLComponents(string:url), ["http","https"].contains(parts.scheme?.lowercased() ?? ""),
                      parts.host?.isEmpty == false, found.insert(tab).inserted else { throw BrowserControlStateError.malformed }
                let heard: Bool
                if let raw = value["heard"] {
                    guard let boolean = raw.bool else { throw BrowserControlStateError.malformed }
                    heard = boolean
                } else { heard = false }
                return .init(key:.init(peer:id,tabID:tab),title:title,url:url,sourceCount:try Self.integer(value["sourceCount"],maximum:4096),heard:heard)
            }
            assignKeys(Set(parsed.map { $0.key.tabID }),peer:&peer)
            let meetings = parsed.map { BrowserMeeting(key:peer.keys[$0.key.tabID] ?? $0.key,title:$0.title,url:$0.url,sourceCount:$0.sourceCount,heard:$0.heard) }
            let previous = Dictionary(uniqueKeysWithValues:peer.meetings.map { ($0.key.tabID,$0.url) })
            if let instance = peer.peer.browserInstance {
                let tabs = Set(meetings.map { $0.key.tabID })
                for otherID in Array(peers.keys) {
                    guard var other = peers[otherID], other.peer.browserInstance == instance,
                          other.connectionOrder < peer.connectionOrder,
                          other.meetings.contains(where:{ tabs.contains($0.key.tabID) }) else { continue }
                    // Two profiles have disjoint tabs. An overlapping newer
                    // connection supersedes this profile's draining old link;
                    // that link must not regain authority on another reconnect.
                    other.superseded = true; peers[otherID] = other
                }
            }
            for meeting in meetings {
                if let old = previous[meeting.key.tabID], Data(old.utf8) != Data(meeting.url.utf8) {
                    peer.autoAttempted.remove(meeting.key.tabID)
                    peer.requestedStops.remove(meeting.key.tabID)
                }
                if let identity = call(meeting,peer:peer) {
                    if newestOwner(peer,tab:meeting.key.tabID) {
                        stoppedCalls.update(identity,previouslyPresent:previous[meeting.key.tabID] != nil,connectedAt:peer.connectedAt,now:clock())
                        rememberContext(.init(call:identity,touched:clock()),key:meeting.key)
                    }
                }
            }
            peer.meetings = meetings
            peer.autoAttempted.formIntersection(Set(meetings.filter { $0.sourceCount > 0 }.map { $0.key.tabID }))
            peer.autoAttempted.formUnion(peer.captures.map { $0.key.tabID })
            peer.autoAttempted.formUnion(peer.interrupted.filter { Self.retained($0,ids:retainedCaptureIDs) }.map { $0.key.tabID })
            peer.autoAttempted.formUnion(peer.pending.values.map { $0.request.key.tabID })
            peer.autoAttempted.formUnion(peer.requestedStops)
        case "status":
            guard peer.hello else { throw BrowserControlStateError.malformed }
            let captures = try Self.captures(json,peer:id), interrupted = try Self.interrupted(json,peer:id)
            assignKeys(Set((captures+interrupted).map { $0.key.tabID }),peer:&peer)
            peer.captures = remap(captures,peer:peer)
            peer.interrupted = remap(interrupted,peer:peer)
            peer.autoAttempted.formUnion(peer.captures.map { $0.key.tabID })
            peer.autoAttempted.formUnion(peer.interrupted.filter { Self.retained($0,ids:retainedCaptureIDs) }.map { $0.key.tabID })
            peer.statusRevision &+= 1
            peer.reconciled = true
        case "result":
            guard peer.hello, let ok = json["ok"]?.bool else { throw BrowserControlStateError.malformed }
            if let number = json["requestId"]?.int, (0...9007199254740991).contains(number) { return }
            guard let requestID = json["requestId"]?.string, !requestID.isEmpty, requestID.unicodeScalars.count <= 128 else { throw BrowserControlStateError.malformed }
            guard let pending = peer.pending[requestID] else { return } // Old/unknown results cannot mutate current state.
            let error = try Self.optionalString(json["error"],maximum:2000)
            if let status = json["status"], !status.isNull {
                let rawCaptures = try Self.captures(status,peer:id), rawInterrupted = try Self.interrupted(status,peer:id)
                assignKeys(Set((rawCaptures+rawInterrupted).map { $0.key.tabID }),peer:&peer)
                let captures = remap(rawCaptures,peer:peer), interrupted = remap(rawInterrupted,peer:peer)
                if pending.request.action == .start, ok, let instance = peer.peer.browserInstance,
                   let url = pending.url, let capture = captures.first(where:{ $0.key == pending.request.key }), let identity = capture.captureID {
                    bind(Data(identity.utf8),to:.init(call:.init(instance:instance,tabID:capture.key.tabID,url:url),touched:clock()))
                }
                if pending.request.action == .start, ok,
                   let identity = captures.first(where:{ $0.key == pending.request.key })?.captureID {
                    // Stop can be queued before Start has published its ID.
                    // Bind that later Stop to this exact successful Start, not
                    // to an unrelated replacement seen in a newer snapshot.
                    for id in Array(peer.pending.keys) {
                        guard let stop = peer.pending[id],stop.request.action == .stop,
                              stop.request.key == pending.request.key,stop.order > pending.order,
                              stop.stopCaptureID == nil else { continue }
                        peer.pending[id] = .init(request:stop.request,statusRevision:stop.statusRevision,order:stop.order,stopCaptureID:identity,url:stop.url)
                    }
                }
                // An asynchronous command result may carry an older replacement
                // snapshot. Never resurrect captures removed by a newer status.
                // Issue order also matters when two independent results share
                // the same full-status baseline. Accept newer results in either
                // arrival order; an older one cannot replace the newer snapshot.
                if peer.statusRevision == pending.statusRevision && pending.order >= peer.lastResultOrder {
                    peer.captures = captures; peer.interrupted = interrupted
                    peer.lastResultOrder = pending.order
                    peer.autoAttempted.formUnion(captures.map { $0.key.tabID })
                    peer.autoAttempted.formUnion(interrupted.filter { Self.retained($0,ids:retainedCaptureIDs) }.map { $0.key.tabID })
                }
            }
            peer.pending.removeValue(forKey:requestID)
            if pending.request.action == .start, ok, let instance = peer.peer.browserInstance, let url = pending.url {
                // A buffered success can arrive from the draining host after
                // its replacement's empty initial status. It confirms an
                // actual Start, so do not start that same call a second time.
                for otherID in Array(peers.keys) {
                    guard var other = peers[otherID], other.connectionOrder > peer.connectionOrder,
                          other.peer.browserInstance == instance,
                          other.meetings.contains(where:{ $0.key == pending.request.key && Data($0.url.utf8) == Data(url.utf8) }) else { continue }
                    other.autoAttempted.insert(pending.request.key.tabID); peers[otherID] = other
                }
            }
            if let original = pending.url, let current = peer.meetings.first(where:{ $0.key == pending.request.key })?.url,
               Data(original.utf8) != Data(current.utf8) {
                // An older command finishing after navigation must not keep
                // its tab-level attempt bit on the new meeting address.
                peer.autoAttempted.remove(pending.request.key.tabID)
            }
            if pending.request.action == .stop && ok {
                peer.requestedStops.remove(pending.request.key.tabID)
                // A still-recording full status may have advanced the baseline
                // while this Stop flushed. Its success still retires that exact
                // capture; otherwise Stop All can send another Stop between the
                // acknowledgement and the following empty status. Never retire
                // a replacement capture which now occupies the same tab.
                if let stopped = pending.stopCaptureID {
                    let identity = Data(stopped.utf8)
                    let before = peer.captures.count + peer.interrupted.count
                    peer.captures.removeAll { $0.key == pending.request.key && $0.captureID.map { Data($0.utf8) } == identity }
                    peer.interrupted.removeAll { $0.key == pending.request.key && $0.captureID.map { Data($0.utf8) } == identity }
                    if before != peer.captures.count + peer.interrupted.count { peer.statusRevision &+= 1 }
                }
            }
            appendOutcome(.init(requestID:requestID,key:pending.request.key,action:pending.request.action,ok:ok,error:error))
        default: return // Forward-compatible messages are not management actions.
        }
        peers[id] = peer
        bindCaptures(peer)
        resolveReturningStarts(peer)
    }
    public mutating func start(_ key: BrowserMeetingKey, microphone: Bool) throws -> BrowserControlRequest {
        guard let owner = owner(key), var peer = peers[owner] else { throw BrowserControlStateError.unavailable }
        let key = peer.keys[key.tabID] ?? key
        guard !peer.superseded else { throw BrowserControlStateError.unavailable }
        guard peer.reconciled else { throw BrowserControlStateError.notReconciled }
        guard !uncertainStart(key) else { throw BrowserControlStateError.busy }
        guard peer.independent else { throw BrowserControlStateError.incompatible }
        guard !peer.interrupted.contains(where:{ $0.key == key && Self.retained($0,ids:retainedCaptureIDs) }) else { throw BrowserControlStateError.busy }
        guard peer.meetings.contains(where:{ $0.key == key && $0.sourceCount > 0 }) else { throw BrowserControlStateError.noSources }
        guard !peer.captures.contains(where:{ $0.key == key }), !peer.pending.values.contains(where:{ $0.request.key == key }) else { throw BrowserControlStateError.busy }
        let stableKey = peer.keys[key.tabID] ?? key
        let request = try Self.command(stableKey,connection:owner,action:.start,independent:true,microphone:microphone)
        guard peer.pending.count < 128 else { throw BrowserControlStateError.limit }
        peer.commandOrder &+= 1
        peer.pending[request.id] = .init(request:request,statusRevision:peer.statusRevision,order:peer.commandOrder,stopCaptureID:nil,url:peer.meetings.first(where:{ $0.key == key })?.url)
        peer.autoAttempted.insert(key.tabID)
        if let context = knownCalls[key] { stoppedCalls.forget(context.call) } // Explicit Record can override Stop.
        peers[owner] = peer
        return request
    }
    /// An explicit Stop suppresses auto-restart until discovery says this call
    /// ended. It may cancel a pending Start; it never targets another profile.
    /// nil means already pending or deferred until drainStops() frees capacity.
    public mutating func stop(_ key: BrowserMeetingKey, captureID: String? = nil, userInitiated: Bool = true) throws -> BrowserControlRequest? {
        if userInitiated { rememberUserStop(key:owner(key).flatMap { peers[$0]?.keys[key.tabID] } ?? key,captureID:captureID) }
        guard let owner = owner(key), var peer = peers[owner] else { throw BrowserControlStateError.unavailable }
        let key = peer.keys[key.tabID] ?? key
        guard !peer.superseded else { throw BrowserControlStateError.unavailable }
        if let captureID, let original = captureCalls[Data(captureID.utf8)],
           knownCalls[key]?.call != original.call { return nil } // An old capture cannot stop the tab's new call.
        guard peer.reconciled else { throw BrowserControlStateError.notReconciled }
        peer.autoAttempted.insert(key.tabID)
        peer.requestedStops.insert(key.tabID)
        if peer.pending.values.contains(where:{ $0.request.key == key && $0.request.action == .stop }) { peers[owner] = peer; return nil }
        let stableKey = peer.keys[key.tabID] ?? key
        let request = try Self.command(stableKey,connection:owner,action:.stop,independent:peer.independent,microphone:false)
        guard peer.pending.count < 128 else { peers[owner] = peer; return nil }
        peer.commandOrder &+= 1
        let target = (peer.captures + peer.interrupted).first { $0.key == key }?.captureID
        peer.pending[request.id] = .init(request:request,statusRevision:peer.statusRevision,order:peer.commandOrder,stopCaptureID:target,url:peer.meetings.first(where:{ $0.key == key })?.url)
        peers[owner] = peer
        return request
    }
    /// Called after every replacement snapshot and when auto-record is enabled.
    /// Reconciliation and the per-call attempt set prevent reconnect/retry loops.
    public mutating func automaticStarts(microphone: Bool) -> [BrowserControlRequest] {
        expireRememberedStops()
        var keys: [BrowserMeetingKey] = []
        for peer in peers.values where peer.reconciled && peer.independent {
            for meeting in peer.meetings where meeting.sourceCount > 0 && (!peer.callEvidence || meeting.heard) && !peer.autoAttempted.contains(meeting.key.tabID) && !peer.requestedStops.contains(meeting.key.tabID) {
                guard newestOwner(peer,tab:meeting.key.tabID) else { continue }
                if uncertainStart(meeting.key,url:meeting.url) { continue }
                if let identity = call(meeting,peer:peer), stoppedCalls.contains(identity) { continue }
                keys.append(meeting.key)
            }
        }
        keys.sort(by:Self.ordered)
        return keys.compactMap { try? start($0,microphone:microphone) }
    }
    /// Explicit Record takes all active meetings, independently of the auto switch.
    public mutating func startAll(microphone: Bool, choices: [BrowserMeetingKey:Bool] = [:]) -> [BrowserControlRequest] {
        let keys = snapshots.filter { $0.reconciled && $0.independent }.flatMap { $0.meetings.filter { $0.sourceCount > 0 }.map(\.key) }
        return keys.compactMap { try? start($0,microphone:choices[$0] ?? microphone) }
    }
    public mutating func stopAll(userInitiated: Bool = true) -> [BrowserControlRequest] {
        if userInitiated {
            for id in retainedCaptureIDs { rememberUserStop(captureID:String(data:id,encoding:.utf8)) }
        }
        var keys = Set<BrowserMeetingKey>()
        for peer in peers.values where !peer.superseded {
            keys.formUnion(peer.captures.map(\.key))
            keys.formUnion(peer.pending.values.map { $0.request.key })
            keys.formUnion(peer.requestedStops.map { BrowserMeetingKey(peer:peer.peer.id,tabID:$0) })
        }
        return keys.sorted(by:Self.ordered).compactMap { try? stop($0,userInitiated:userInitiated) }
    }
    /// Drain after results/timeouts free space. Stop intent survives a full
    /// command window instead of being lost when many starts are pending.
    public mutating func drainStops() -> [BrowserControlRequest] {
        var keys: [BrowserMeetingKey] = []
        for peer in peers.values where !peer.superseded { keys += peer.requestedStops.map { BrowserMeetingKey(peer:peer.peer.id,tabID:$0) } }
        return keys.sorted(by:Self.ordered).compactMap { try? stop($0,userInitiated:false) }
    }
    private static func ordered(_ a: BrowserMeetingKey, _ b: BrowserMeetingKey) -> Bool {
        a.peer == b.peer ? a.tabID < b.tabID : a.peer.uuidString < b.peer.uuidString
    }
    /// Timeouts/failed sends are not retried blindly: a Start may have succeeded.
    public mutating func failed(_ request: BrowserControlRequest) {
        guard var peer = peers[request.connectionID], peer.pending.removeValue(forKey:request.id) != nil else { return }
        peers[request.connectionID] = peer
        appendOutcome(.init(requestID:request.id,key:request.key,action:request.action,ok:false,error:nil))
    }
    private mutating func appendOutcome(_ outcome: BrowserControlOutcome) {
        deliveries.append(outcome)
        outcomes.append(outcome); if outcomes.count > 128 { outcomes.removeFirst(outcomes.count-128) }
    }
    private static func command(_ key: BrowserMeetingKey, connection: UUID, action: BrowserControlAction, independent: Bool, microphone: Bool) throws -> BrowserControlRequest {
        guard (0...9007199254740991).contains(key.tabID) else { throw BrowserControlStateError.malformed }
        let id = UUID().uuidString.lowercased()
        var fields: [(String,JSON)] = [("type",.string("command")),("requestId",.string(id)),("action",.string(action.rawValue)),("tabId",.number(String(key.tabID)))]
        if independent { fields.append(("independent",.bool(true))) }
        if action == .start { fields += [("mode",.string("tracks")),("captureLocal",.bool(false)),("microphone",.bool(microphone))] }
        return .init(id:id,key:key,connectionID:connection,action:action,data:try JSON.object(fields).encoded(maximumBytes:FrameIO.maximum))
    }
    private static func integer(_ value: JSON?, maximum: Int = 9007199254740991) throws -> Int {
        guard let integer = value?.int, (0...maximum).contains(integer) else { throw BrowserControlStateError.malformed }; return integer
    }
    private static func string(_ value: JSON?, maximum: Int) throws -> String {
        guard let string = value?.string, string.unicodeScalars.count <= maximum else { throw BrowserControlStateError.malformed }; return string
    }
    private static func optionalString(_ value: JSON?, maximum: Int) throws -> String? {
        guard let value, !value.isNull else { return nil }; return try string(value,maximum:maximum)
    }
    private static func interrupted(_ json: JSON, peer: UUID) throws -> [BrowserCaptureStatus] {
        guard let raw = json["interrupted"],!raw.isNull else { return [] }
        guard let list = raw.array,list.count <= 100 else { throw BrowserControlStateError.malformed }
        let wrapper = JSON.object([("type",.string("status")),("recording",.bool(false)),("tabId",.null),("path",.null),("message",.string("")),("sessions",.array(list))])
        return try captures(wrapper,peer:peer,includeInactive:true)
    }
    private static func captures(_ json: JSON, peer: UUID, includeInactive: Bool = false) throws -> [BrowserCaptureStatus] {
        guard json["type"]?.string == "status", let recording = json["recording"]?.bool else { throw BrowserControlStateError.malformed }
        guard json["tabId"] != nil, json["path"] != nil else { throw BrowserControlStateError.malformed }
        if let tab = json["tabId"], !tab.isNull { _ = try integer(tab) }
        _ = try optionalString(json["path"],maximum:4096)
        _ = try string(json["message"],maximum:2000)
        if let tracks = json["tracks"] { _ = try integer(tracks) }
        if let stopping = json["stopping"], stopping.bool == nil { throw BrowserControlStateError.malformed }
        let entries: [JSON]
        if let sessions = json["sessions"], !sessions.isNull {
            guard let list = sessions.array, list.count <= 100 else { throw BrowserControlStateError.malformed }; entries = list
        } else { entries = recording ? [json] : [] }
        var found = Set<Int>()
        return try entries.compactMap { value -> BrowserCaptureStatus? in
            guard value["tabId"] != nil, value["path"] != nil, let recording = value["recording"]?.bool else { throw BrowserControlStateError.malformed }
            let stopping = try value["stopping"].map { item -> Bool in guard let flag = item.bool else { throw BrowserControlStateError.malformed }; return flag } ?? false
            let capture = try optionalString(value["captureId"],maximum:128)
            guard capture?.isEmpty != true else { throw BrowserControlStateError.malformed }
            _ = try string(value["message"],maximum:2000)
            let path = try optionalString(value["path"],maximum:4096)
            let tracks = try value["tracks"].map { try integer($0) } ?? 0
            // v1 permits an unknown tab. Such a status is advisory, not an
            // actionable meeting key; inactive entries cannot reserve a tab.
            guard value["tabId"]?.isNull != true else { return nil }
            let tab = try integer(value["tabId"])
            guard found.insert(tab).inserted else { throw BrowserControlStateError.malformed }
            guard recording || stopping || includeInactive else { return nil }
            return .init(key:.init(peer:peer,tabID:tab),captureID:capture,path:path,recording:recording,stopping:stopping,tracks:tracks)
        }
    }
}
