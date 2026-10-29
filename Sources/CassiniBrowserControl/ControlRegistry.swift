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
    }
    private struct PeerState: Sendable {
        let peer: BrowserPeer
        var hello = false, independent = false, reconciled = false
        var statusRevision: UInt64 = 0
        var commandOrder: UInt64 = 0, lastResultOrder: UInt64 = 0
        var meetings: [BrowserMeeting] = []
        var captures: [BrowserCaptureStatus] = []
        var interrupted: [BrowserCaptureStatus] = []
        var pending: [String:Pending] = [:]
        var autoAttempted: Set<Int> = []
        var requestedStops: Set<Int> = []
    }
    private var peers: [UUID:PeerState] = [:]
    private var retainedCaptureIDs: Set<Data> = []
    public private(set) var outcomes: [BrowserControlOutcome] = []
    public init() {}
    public var snapshots: [BrowserControlPeerSnapshot] {
        peers.values.sorted { $0.peer.id.uuidString < $1.peer.id.uuidString }.map {
            .init(id:$0.peer.id,browser:$0.peer.browser,reconciled:$0.reconciled,independent:$0.independent,meetings:$0.meetings,captures:$0.captures,interrupted:$0.interrupted)
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
        guard peer.role == .control, peers[peer.id] == nil, peers.count < 128 else { throw BrowserControlStateError.unavailable }
        peers[peer.id] = PeerState(peer:peer)
    }
    public mutating func disconnect(_ id: UUID) {
        guard let peer = peers.removeValue(forKey:id) else { return }
        for pending in peer.pending.values {
            appendOutcome(.init(requestID:pending.request.id,key:pending.request.key,action:pending.request.action,ok:false,error:nil))
        }
    }
    public mutating func receive(_ bytes: Data, from id: UUID) throws {
        let json = try JSONParser.parse(FrameIO.normalized(bytes))
        guard var peer = peers[id], let type = json["type"]?.string else { throw BrowserControlStateError.malformed }
        switch type {
        case "hello":
            guard !peer.hello, json["version"]?.int == 1 else { throw BrowserControlStateError.malformed }
            if let raw = json["capabilities"], !raw.isNull {
                guard let values = raw.array, values.allSatisfy({ $0.string != nil }) else { throw BrowserControlStateError.malformed }
                peer.independent = values.contains { $0.string == "independent-sessions-v1" }
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
                return .init(key:.init(peer:id,tabID:tab),title:title,url:url,sourceCount:try Self.integer(value["sourceCount"],maximum:4096))
            }
            peer.meetings = meetings
            peer.autoAttempted.formIntersection(Set(meetings.filter { $0.sourceCount > 0 }.map { $0.key.tabID }))
            peer.autoAttempted.formUnion(peer.captures.map { $0.key.tabID })
            peer.autoAttempted.formUnion(peer.interrupted.filter { Self.retained($0,ids:retainedCaptureIDs) }.map { $0.key.tabID })
            peer.autoAttempted.formUnion(peer.pending.values.map { $0.request.key.tabID })
            peer.autoAttempted.formUnion(peer.requestedStops)
        case "status":
            guard peer.hello else { throw BrowserControlStateError.malformed }
            peer.captures = try Self.captures(json,peer:id)
            peer.interrupted = try Self.interrupted(json,peer:id)
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
                let captures = try Self.captures(status,peer:id)
                let interrupted = try Self.interrupted(status,peer:id)
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
            if pending.request.action == .stop && ok { peer.requestedStops.remove(pending.request.key.tabID) }
            appendOutcome(.init(requestID:requestID,key:pending.request.key,action:pending.request.action,ok:ok,error:error))
        default: return // Forward-compatible messages are not management actions.
        }
        peers[id] = peer
    }
    public mutating func start(_ key: BrowserMeetingKey, microphone: Bool) throws -> BrowserControlRequest {
        guard var peer = peers[key.peer] else { throw BrowserControlStateError.unavailable }
        guard peer.reconciled else { throw BrowserControlStateError.notReconciled }
        guard peer.independent else { throw BrowserControlStateError.incompatible }
        guard !peer.interrupted.contains(where:{ $0.key == key && Self.retained($0,ids:retainedCaptureIDs) }) else { throw BrowserControlStateError.busy }
        guard peer.meetings.contains(where:{ $0.key == key && $0.sourceCount > 0 }) else { throw BrowserControlStateError.noSources }
        guard !peer.captures.contains(where:{ $0.key == key }), !peer.pending.values.contains(where:{ $0.request.key == key }) else { throw BrowserControlStateError.busy }
        let request = try Self.command(key,action:.start,independent:true,microphone:microphone)
        guard peer.pending.count < 128 else { throw BrowserControlStateError.limit }
        peer.commandOrder &+= 1
        peer.pending[request.id] = .init(request:request,statusRevision:peer.statusRevision,order:peer.commandOrder)
        peer.autoAttempted.insert(key.tabID)
        peers[key.peer] = peer
        return request
    }
    /// An explicit Stop suppresses auto-restart until discovery says this call
    /// ended. It may cancel a pending Start; it never targets another profile.
    /// nil means already pending or deferred until drainStops() frees capacity.
    public mutating func stop(_ key: BrowserMeetingKey) throws -> BrowserControlRequest? {
        guard var peer = peers[key.peer] else { throw BrowserControlStateError.unavailable }
        guard peer.reconciled else { throw BrowserControlStateError.notReconciled }
        peer.autoAttempted.insert(key.tabID)
        peer.requestedStops.insert(key.tabID)
        if peer.pending.values.contains(where:{ $0.request.key == key && $0.request.action == .stop }) { peers[key.peer] = peer; return nil }
        let request = try Self.command(key,action:.stop,independent:peer.independent,microphone:false)
        guard peer.pending.count < 128 else { peers[key.peer] = peer; return nil }
        peer.commandOrder &+= 1
        peer.pending[request.id] = .init(request:request,statusRevision:peer.statusRevision,order:peer.commandOrder)
        peers[key.peer] = peer
        return request
    }
    /// Called after every replacement snapshot and when auto-record is enabled.
    /// Reconciliation and the per-call attempt set prevent reconnect/retry loops.
    public mutating func automaticStarts(microphone: Bool) -> [BrowserControlRequest] {
        var keys: [BrowserMeetingKey] = []
        for peer in peers.values where peer.reconciled && peer.independent {
            for meeting in peer.meetings where meeting.sourceCount > 0 && !peer.autoAttempted.contains(meeting.key.tabID) && !peer.requestedStops.contains(meeting.key.tabID) {
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
    public mutating func stopAll() -> [BrowserControlRequest] {
        var keys = Set<BrowserMeetingKey>()
        for peer in peers.values {
            keys.formUnion(peer.captures.map(\.key))
            keys.formUnion(peer.pending.values.map { $0.request.key })
            keys.formUnion(peer.requestedStops.map { BrowserMeetingKey(peer:peer.peer.id,tabID:$0) })
        }
        return keys.sorted(by:Self.ordered).compactMap { try? stop($0) }
    }
    /// Drain after results/timeouts free space. Stop intent survives a full
    /// command window instead of being lost when many starts are pending.
    public mutating func drainStops() -> [BrowserControlRequest] {
        var keys: [BrowserMeetingKey] = []
        for peer in peers.values { keys += peer.requestedStops.map { BrowserMeetingKey(peer:peer.peer.id,tabID:$0) } }
        return keys.sorted(by:Self.ordered).compactMap { try? stop($0) }
    }
    private static func ordered(_ a: BrowserMeetingKey, _ b: BrowserMeetingKey) -> Bool {
        a.peer == b.peer ? a.tabID < b.tabID : a.peer.uuidString < b.peer.uuidString
    }
    /// Timeouts/failed sends are not retried blindly: a Start may have succeeded.
    public mutating func failed(_ request: BrowserControlRequest) {
        guard var peer = peers[request.key.peer], peer.pending.removeValue(forKey:request.id) != nil else { return }
        peers[request.key.peer] = peer
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
