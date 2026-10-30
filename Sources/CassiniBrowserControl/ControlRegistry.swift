// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import CassiniKit

public struct BrowserMeetingKey: Hashable, Sendable {
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
        // Native hello identifies the browser process, not its profile. Tab
        // overlap identifies connection lineage; keep bounded history through
        // empty inventories so an established profile never becomes ambiguous.
        var lineage: UUID?
        var observedTabs: [Int:TimeInterval] = [:]
        var absentSince: [Int:TimeInterval] = [:]
    }
    private struct CallContext: Sendable { let call: BrowserCallIdentity; var touched: TimeInterval }
    private var stoppedCalls = UserStoppedCalls()
    private var knownCalls: [BrowserMeetingKey:CallContext] = [:]
    private var captureCalls: [Data:CallContext] = [:]
    private var unretiredCaptures: [Data:TimeInterval] = [:]
    private var captureAuthority: [Data:UInt64] = [:]
    private struct CaptureStop: Sendable { var touched: TimeInterval }
    private var captureStops: [Data:CaptureStop] = [:]
    private struct IssuedCall: Sendable { let key: BrowserMeetingKey; let context: CallContext }
    private var unboundStarts: [String:IssuedCall] = [:]
    private let clock: @Sendable () -> TimeInterval
    private let instanceAlive: @Sendable (BrowserInstance) -> Bool?
    private var connectionOrder: UInt64 = 0
    private var peers: [UUID:PeerState] = [:]
    private var retainedCaptureIDs: Set<Data> = []
    public private(set) var outcomes: [BrowserControlOutcome] = []
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
    private func mayRemoveStops(_ peer: PeerState) -> Bool {
        guard !peer.superseded, let instance = peer.peer.browserInstance else { return !peer.superseded }
        // A newer identified, disjoint profile has no authority over this
        // owner's Stops. A still-unidentified connection could be its empty
        // replacement: preserve the conservative veto until discovery resolves
        // that ambiguity. Established lineage survives later empty inventories.
        return !peers.values.contains {
            $0.peer.browserInstance == instance && $0.connectionOrder > peer.connectionOrder && $0.reconciled &&
                ($0.lineage == nil || $0.lineage == peer.lineage)
        }
    }
    private mutating func identifyLineage(_ peer: inout PeerState, tabs: Set<Int>) {
        guard let instance = peer.peer.browserInstance, !tabs.isEmpty else { return }
        let related = peers.values.filter {
            $0.peer.browserInstance == instance &&
                $0.observedTabs.keys.contains(where:{ tabs.contains($0) })
        }
        // A partial inventory can reveal the link only later. Merge its earlier
        // provisional lineage with the observed owner rather than losing that
        // connection's history when the overlapping tab finally arrives.
        var lineages = Set(related.compactMap(\.lineage))
        if let lineage = peer.lineage { lineages.insert(lineage) }
        let lineage = related.min(by:{ $0.connectionOrder < $1.connectionOrder })?.lineage ?? peer.lineage ?? peer.peer.id
        peer.lineage = lineage
        for id in Array(peers.keys) where id != peer.peer.id {
            guard var other = peers[id], other.peer.browserInstance == instance,
                  let original = other.lineage, lineages.contains(original) else { continue }
            other.lineage = lineage
            if other.connectionOrder < peer.connectionOrder { other.superseded = true }
            else if other.connectionOrder > peer.connectionOrder { peer.superseded = true }
            stoppedCalls.resolveLineage(.init(connection:id,lineage:lineage),superseded:other.superseded,now:clock())
            peers[id] = other
        }
        stoppedCalls.resolveLineage(.init(connection:peer.peer.id,lineage:lineage),superseded:peer.superseded,now:clock())
        for tab in tabs { peer.observedTabs[tab] = clock() }
        // At most100 incoming tabs and256 historical tabs per live connection;
        // preserve the current inventory when fake/real clock values tie.
        while peer.observedTabs.count > UserStoppedCalls.limit {
            guard let oldest = peer.observedTabs.filter({ !tabs.contains($0.key) }).min(by:{ $0.value < $1.value })?.key else { break }
            peer.observedTabs.removeValue(forKey:oldest)
        }
    }
    /// Runs before replacing inventories, including the first inventory after
    /// reconnect. Only the old live inventory can protect an otherwise old Stop.
    public mutating func expireRememberedStops() {
        let now = clock()
        let live = Set(peers.values.flatMap { peer in peer.meetings.filter { newestOwner(peer,tab:$0.key.tabID) }.compactMap { call($0,peer:peer) } })
        stoppedCalls.expire(now:now,priorLive:live,alive:instanceAlive)
        knownCalls = knownCalls.filter { now-$0.value.touched < UserStoppedCalls.retention || live.contains($0.value.call) }
        captureCalls = captureCalls.filter { retainedCaptureIDs.contains($0.key) || now-$0.value.touched < UserStoppedCalls.retention }
        unretiredCaptures = unretiredCaptures.filter { retainedCaptureIDs.contains($0.key) || now-$0.value < UserStoppedCalls.retention }
        captureAuthority = captureAuthority.filter { captureCalls[$0.key] != nil || unretiredCaptures[$0.key] != nil }
        captureStops = captureStops.filter { retainedCaptureIDs.contains($0.key) || now-$0.value.touched < UserStoppedCalls.retention }
        unboundStarts = unboundStarts.filter { now-$0.value.context.touched < UserStoppedCalls.retention && instanceAlive($0.value.context.call.instance) != false }
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
            if capture.recording || capture.stopping || unretiredCaptures[id] != nil || retainedCaptureIDs.contains(id) {
                unretiredCaptures[id] = clock()
            }
            if unretiredCaptures.count > UserStoppedCalls.limit, let oldest = unretiredCaptures.min(by:{ $0.value < $1.value })?.key { unretiredCaptures.removeValue(forKey:oldest) }
            captureAuthority[id] = max(captureAuthority[id] ?? 0,peer.connectionOrder)
            if var original = captureCalls[id] { original.touched = clock(); captureCalls[id] = original; continue }
            let candidates = unboundStarts.filter { $0.value.context.call.instance == peer.peer.browserInstance && $0.value.key.tabID == capture.key.tabID }
            let pending = peer.pending.values.first { $0.request.action == .start && $0.request.key == capture.key }
            let reportedURL = peer.meetings.first(where:{ $0.key == capture.key })?.url
            // A disconnected, unbound Start is not proof that a newly reported
            // capture belongs to it after navigation. Keep the ID unresolved
            // rather than borrowing either address across that ambiguity.
            if pending == nil, !candidates.isEmpty,
               !candidates.values.contains(where:{ start in reportedURL.map { Data($0.utf8) == Data(start.context.call.url.utf8) } == true }) { continue }
            let matching = candidates.filter { start in reportedURL.map { Data($0.utf8) == Data(start.value.context.call.url.utf8) } == true }
            let original = matching.count == 1 ? matching.first : nil
            let requestedURL = pending?.url ?? reportedURL
            if let instance = peer.peer.browserInstance,
               let url = requestedURL ?? peer.meetings.first(where:{ $0.key == capture.key })?.url {
                bind(id,to:.init(call:.init(instance:instance,tabID:capture.key.tabID,url:url),touched:clock()))
            } else if let context = knownCalls[capture.key] { bind(id,to:context) }
            if captureCalls[id] != nil {
                if let pending { unboundStarts.removeValue(forKey:pending.request.id) }
                else if let original { unboundStarts.removeValue(forKey:original.key) }
            }
        }
    }
    private mutating func bind(_ id: Data, to context: CallContext) {
        guard captureCalls[id] == nil else { return }
        captureCalls[id] = context
        if captureStops[id] != nil { stoppedCalls.remember(context.call,now:clock()) }
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
        if let captureID {
            let id = Data(captureID.utf8)
            captureStops[id] = .init(touched:clock())
            if captureStops.count > UserStoppedCalls.limit, let oldest = captureStops.min(by:{ $0.value.touched < $1.value.touched })?.key { captureStops.removeValue(forKey:oldest) }
            context = captureCalls[id]
            if context == nil, let key {
                // An issued Start has an immutable URL even if discovery
                // navigated or its control peer disconnected meanwhile.
                for start in unboundStarts.values where start.key == key { stoppedCalls.remember(start.context.call,now:clock()) }
            }
        }
        else { context = key.flatMap { knownCalls[$0] } }
        if let context { stoppedCalls.remember(context.call,now:clock()) }
    }
    private mutating func retireMissing(_ previous: [BrowserCaptureStatus], current: [BrowserCaptureStatus], peer: PeerState) {
        let active = Set(current.compactMap { $0.captureID.map { Data($0.utf8) } })
        for id in previous.compactMap({ $0.captureID.map { Data($0.utf8) } }) where !active.contains(id) {
            if peer.connectionOrder >= (captureAuthority[id] ?? 0) { unretiredCaptures.removeValue(forKey:id) }
        }
    }
    public var snapshots: [BrowserControlPeerSnapshot] {
        peers.values.filter { !$0.superseded }.sorted { $0.peer.id.uuidString < $1.peer.id.uuidString }.map {
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
        for pending in peer.pending.values {
            appendOutcome(.init(requestID:pending.request.id,key:pending.request.key,action:pending.request.action,ok:false,error:nil))
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
            let meetings = try values.map { value -> BrowserMeeting in
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
            let previous = Dictionary(uniqueKeysWithValues:peer.meetings.map { ($0.key.tabID,$0.url) })
            let incomingTabs = Set(meetings.map { $0.key.tabID })
            for tab in previous.keys where !incomingTabs.contains(tab) { peer.absentSince[tab] = clock() }
            peer.absentSince = peer.absentSince.filter { clock()-$0.value < UserStoppedCalls.retention }
            if peer.absentSince.count > UserStoppedCalls.limit {
                let keep = peer.absentSince.sorted { $0.value > $1.value }.prefix(UserStoppedCalls.limit)
                peer.absentSince = Dictionary(uniqueKeysWithValues:keep.map { ($0.key,$0.value) })
            }
            identifyLineage(&peer, tabs:incomingTabs)
            for meeting in meetings {
                if let old = previous[meeting.key.tabID], Data(old.utf8) != Data(meeting.url.utf8) {
                    peer.autoAttempted.remove(meeting.key.tabID)
                    peer.requestedStops.remove(meeting.key.tabID)
                }
                if let identity = call(meeting,peer:peer) {
                    if newestOwner(peer,tab:meeting.key.tabID) {
                        stoppedCalls.update(identity,absentSince:peer.absentSince[meeting.key.tabID],mayRemove:mayRemoveStops(peer),now:clock(),retiredBy:.init(connection:peer.peer.id,lineage:peer.lineage ?? peer.peer.id))
                    }
                    rememberContext(.init(call:identity,touched:clock()),key:meeting.key)
                }
            }
            for tab in incomingTabs { peer.absentSince.removeValue(forKey:tab) }
            peer.meetings = meetings
            peer.autoAttempted.formIntersection(Set(meetings.filter { $0.sourceCount > 0 }.map { $0.key.tabID }))
            peer.autoAttempted.formUnion(peer.captures.map { $0.key.tabID })
            peer.autoAttempted.formUnion(peer.interrupted.filter { Self.retained($0,ids:retainedCaptureIDs) }.map { $0.key.tabID })
            peer.autoAttempted.formUnion(peer.pending.values.map { $0.request.key.tabID })
            peer.autoAttempted.formUnion(peer.requestedStops)
        case "status":
            guard peer.hello else { throw BrowserControlStateError.malformed }
            let captures = try Self.captures(json,peer:id), interrupted = try Self.interrupted(json,peer:id)
            retireMissing(peer.captures+peer.interrupted,current:captures+interrupted,peer:peer)
            peer.captures = captures; peer.interrupted = interrupted
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
            if !ok, pending.request.action == .start { unboundStarts.removeValue(forKey:requestID) }
            if let status = json["status"], !status.isNull {
                let captures = try Self.captures(status,peer:id)
                let interrupted = try Self.interrupted(status,peer:id)
                if pending.request.action == .start, ok, let instance = peer.peer.browserInstance,
                   let url = pending.url, let capture = captures.first(where:{ $0.key == pending.request.key }), let identity = capture.captureID {
                    bind(Data(identity.utf8),to:.init(call:.init(instance:instance,tabID:capture.key.tabID,url:url),touched:clock()))
                    unboundStarts.removeValue(forKey:requestID)
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
                    retireMissing(peer.captures+peer.interrupted,current:captures+interrupted,peer:peer)
                    peer.captures = captures; peer.interrupted = interrupted
                    peer.lastResultOrder = pending.order
                    peer.autoAttempted.formUnion(captures.map { $0.key.tabID })
                    peer.autoAttempted.formUnion(interrupted.filter { Self.retained($0,ids:retainedCaptureIDs) }.map { $0.key.tabID })
                }
            }
            peer.pending.removeValue(forKey:requestID)
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
                    if peer.connectionOrder >= (captureAuthority[identity] ?? 0) {
                        unretiredCaptures.removeValue(forKey:identity)
                        if captureCalls[identity] != nil { captureStops.removeValue(forKey:identity) }
                    }
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
    }
    public mutating func start(_ key: BrowserMeetingKey, microphone: Bool, automatic: Bool = false) throws -> BrowserControlRequest {
        guard var peer = peers[key.peer] else { throw BrowserControlStateError.unavailable }
        guard !peer.superseded else { throw BrowserControlStateError.unavailable }
        guard peer.reconciled else { throw BrowserControlStateError.notReconciled }
        guard peer.independent else { throw BrowserControlStateError.incompatible }
        guard !peer.interrupted.contains(where:{ $0.key == key && Self.retained($0,ids:retainedCaptureIDs) }) else { throw BrowserControlStateError.busy }
        guard let meeting = peer.meetings.first(where:{ $0.key == key && $0.sourceCount > 0 }) else { throw BrowserControlStateError.noSources }
        if automatic, let identity = call(meeting,peer:peer), stoppedCalls.contains(identity) { throw BrowserControlStateError.busy }
        guard !peer.captures.contains(where:{ $0.key == key }), !peer.pending.values.contains(where:{ $0.request.key == key }) else { throw BrowserControlStateError.busy }
        let request = try Self.command(key,action:.start,independent:true,microphone:microphone)
        guard peer.pending.count < 128 else { throw BrowserControlStateError.limit }
        peer.commandOrder &+= 1
        peer.pending[request.id] = .init(request:request,statusRevision:peer.statusRevision,order:peer.commandOrder,stopCaptureID:nil,url:peer.meetings.first(where:{ $0.key == key })?.url)
        peer.autoAttempted.insert(key.tabID)
        if let identity = call(meeting,peer:peer) {
            if !automatic { stoppedCalls.forget(identity) } // Only explicit Record can override Stop.
            unboundStarts[request.id] = .init(key:key,context:.init(call:identity,touched:clock()))
            if unboundStarts.count > UserStoppedCalls.limit, let oldest = unboundStarts.min(by:{ $0.value.context.touched < $1.value.context.touched })?.key { unboundStarts.removeValue(forKey:oldest) }
        }
        peers[key.peer] = peer
        return request
    }
    /// An explicit Stop suppresses auto-restart until discovery says this call
    /// ended. It may cancel a pending Start; it never targets another profile.
    /// nil means already pending or deferred until drainStops() frees capacity.
    public mutating func stop(_ key: BrowserMeetingKey, captureID: String? = nil, userInitiated: Bool = true) throws -> BrowserControlRequest? {
        let currentCapture = peers[key.peer].flatMap { ($0.captures+$0.interrupted).first { $0.key == key } }?.captureID
        let originalCapture = captureID ?? currentCapture
        if userInitiated { rememberUserStop(key:key,captureID:originalCapture) }
        guard var peer = peers[key.peer] else { throw BrowserControlStateError.unavailable }
        guard !peer.superseded else { throw BrowserControlStateError.unavailable }
        if let captureID, let currentCapture, Data(captureID.utf8) != Data(currentCapture.utf8) { return nil }
        if let captureID, currentCapture == nil, let original = captureCalls[Data(captureID.utf8)],
           knownCalls[key]?.call != original.call { return nil } // An old capture cannot stop the tab's new call.
        guard peer.reconciled else { throw BrowserControlStateError.notReconciled }
        peer.autoAttempted.insert(key.tabID)
        peer.requestedStops.insert(key.tabID)
        if peer.pending.values.contains(where:{ $0.request.key == key && $0.request.action == .stop }) { peers[key.peer] = peer; return nil }
        let request = try Self.command(key,action:.stop,independent:peer.independent,microphone:false)
        guard peer.pending.count < 128 else { peers[key.peer] = peer; return nil }
        peer.commandOrder &+= 1
        let target = currentCapture
        let originalURL = target.flatMap { captureCalls[Data($0.utf8)]?.call.url }
            ?? peer.pending.values.first(where:{ $0.request.key == key && $0.request.action == .start })?.url
            ?? peer.meetings.first(where:{ $0.key == key })?.url
        peer.pending[request.id] = .init(request:request,statusRevision:peer.statusRevision,order:peer.commandOrder,stopCaptureID:target,url:originalURL)
        peers[key.peer] = peer
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
                if let identity = call(meeting,peer:peer), stoppedCalls.contains(identity) { continue }
                keys.append(meeting.key)
            }
        }
        keys.sort(by:Self.ordered)
        return keys.compactMap { try? start($0,microphone:microphone,automatic:true) }
    }
    /// Explicit Record takes all active meetings, independently of the auto switch.
    public mutating func startAll(microphone: Bool, choices: [BrowserMeetingKey:Bool] = [:]) -> [BrowserControlRequest] {
        let keys = snapshots.filter { $0.reconciled && $0.independent }.flatMap { $0.meetings.filter { $0.sourceCount > 0 }.map(\.key) }
        return keys.compactMap { try? start($0,microphone:choices[$0] ?? microphone) }
    }
    public mutating func stopAll(userInitiated: Bool = true) -> [BrowserControlRequest] {
        if userInitiated {
            for id in Set(unretiredCaptures.keys).union(retainedCaptureIDs) { rememberUserStop(captureID:String(data:id,encoding:.utf8)) }
            for start in unboundStarts.values { stoppedCalls.remember(start.context.call,now:clock()) }
            for peer in peers.values {
                guard let instance = peer.peer.browserInstance else { continue }
                for pending in peer.pending.values {
                    if let url = pending.url { stoppedCalls.remember(.init(instance:instance,tabID:pending.request.key.tabID,url:url),now:clock()) }
                }
            }
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
        var requests = keys.sorted(by:Self.ordered).compactMap { try? stop($0,userInitiated:false) }
        // A Stop can precede ID binding or control reconciliation. When that
        // same capture returns, send its queued Stop without targeting a
        // replacement capture or treating a missing URL as a wildcard.
        let returning = snapshots.flatMap { $0.captures + $0.interrupted }
        for capture in returning {
            guard capture.recording || capture.stopping,
                  let id = capture.captureID, captureStops[Data(id.utf8)] != nil,
                  let request = try? stop(capture.key,captureID:id,userInitiated:false) else { continue }
            requests.append(request)
        }
        return requests
    }
    private static func ordered(_ a: BrowserMeetingKey, _ b: BrowserMeetingKey) -> Bool {
        a.peer == b.peer ? a.tabID < b.tabID : a.peer.uuidString < b.peer.uuidString
    }
    /// Timeouts/failed sends are not retried blindly: a Start may have succeeded.
    public mutating func failed(_ request: BrowserControlRequest) {
        guard var peer = peers[request.key.peer], peer.pending.removeValue(forKey:request.id) != nil else { return }
        peers[request.key.peer] = peer
        if request.action == .start { unboundStarts.removeValue(forKey:request.id) }
        appendOutcome(.init(requestID:request.id,key:request.key,action:request.action,ok:false,error:nil))
    }
    private mutating func appendOutcome(_ outcome: BrowserControlOutcome) {
        outcomes.append(outcome); if outcomes.count > 128 { outcomes.removeFirst(outcomes.count-128) }
    }
    private static func command(_ key: BrowserMeetingKey, action: BrowserControlAction, independent: Bool, microphone: Bool) throws -> BrowserControlRequest {
        guard (0...9007199254740991).contains(key.tabID) else { throw BrowserControlStateError.malformed }
        let id = UUID().uuidString.lowercased()
        var fields: [(String,JSON)] = [("type",.string("command")),("requestId",.string(id)),("action",.string(action.rawValue)),("tabId",.number(String(key.tabID)))]
        if independent { fields.append(("independent",.bool(true))) }
        if action == .start { fields += [("mode",.string("tracks")),("captureLocal",.bool(false)),("microphone",.bool(microphone))] }
        return .init(id:id,key:key,action:action,data:try JSON.object(fields).encoded(maximumBytes:FrameIO.maximum))
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
