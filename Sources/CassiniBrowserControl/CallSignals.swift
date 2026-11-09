// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import CassiniKit

/// D74 wire facts. A full snapshot is validated before replacing any eligibility.
public struct BrowserCallSignal: Equatable, Sendable {
    public let tabID: Int
    public let url: String
    public let document: String
    public let remoteAudio: String
    public let state: String
    public let reason: String
    public let site: String?
    public let generation: String?
    public var sourceDocument: String? = nil
    public var eligible: Bool { state == "active" && remoteAudio == "mixed" }
}
public struct BrowserCallSignalSnapshot: Equatable, Sendable {
    public let instance: String
    public let sequence: Int
    public let tabs: [BrowserCallSignal]
    static func read(_ json: JSON, verified: Bool = false) throws -> Self {
        func keys(_ value: JSON, _ expected: Set<String>) throws {
            guard let pairs = value.object, Set(pairs.map(\.0)) == expected else { throw BrowserControlStateError.malformed }
        }
        func text(_ value: JSON?, _ bound: Int = 200) throws -> String {
            guard let s = value?.string, !s.isEmpty, s.utf8.count <= bound else { throw BrowserControlStateError.malformed }; return s
        }
        func integer(_ value: JSON?) throws -> Int {
            guard case .number(let literal)? = value, let n = Int(literal), n >= 0, n <= 9_007_199_254_740_991 else { throw BrowserControlStateError.malformed }; return n
        }
        try keys(json,["type","browserInstance","sequence","tabs"])
        let instance = try text(json["browserInstance"]), sequence = try integer(json["sequence"])
        guard let raw = json["tabs"]?.array, raw.count <= 100 else { throw BrowserControlStateError.malformed }
        var seen: Set<Int> = []
        let tabs = try raw.map { row -> BrowserCallSignal in
            let hasAlias = row["sourceDocumentGeneration"] != nil
            guard !verified || hasAlias else { throw BrowserControlStateError.malformed }
            try keys(row,hasAlias ? ["tabId","url","documentGeneration","sourceDocumentGeneration","remoteAudio","callEvidence"] : ["tabId","url","documentGeneration","remoteAudio","callEvidence"])
            let sourceDocument = row["sourceDocumentGeneration"] == nil || row["sourceDocumentGeneration"] == .null ? nil : try text(row["sourceDocumentGeneration"])
            let tab = try integer(row["tabId"]), url = try text(row["url"],8192), document = try text(row["documentGeneration"])
            guard seen.insert(tab).inserted, url.unicodeScalars.count <= 2048, let parsed = URLComponents(string:url),
                  ["http","https"].contains(parsed.scheme), parsed.host?.isEmpty == false,
                  let remote = row["remoteAudio"]?.string, ["mixed","separated","unknown"].contains(remote),
                  let evidence = row["callEvidence"] else { throw BrowserControlStateError.malformed }
            try keys(evidence,["state","reason","adapter","callGeneration"])
            let state = try text(evidence["state"]), reason = try text(evidence["reason"])
            let generation = evidence["callGeneration"] == .null ? nil : try text(evidence["callGeneration"])
            var site: String?
            if let adapter = evidence["adapter"], adapter != .null {
                try keys(adapter,["name","version"])
                let name = try text(adapter["name"],320), version = try text(adapter["version"],320)
                guard name.unicodeScalars.count <= 80, version.unicodeScalars.count <= 80 else { throw BrowserControlStateError.malformed }; site = name
            }
            guard (remote == "unknown" && state == "unknown" || site != nil),
                  (state == "active" && reason == "activeCall" && generation != nil ||
                   state == "inactive" && ["callEnded","nonCall"].contains(reason) && (reason != "callEnded" || generation != nil) ||
                   state == "unknown" && ["unverified","unsupported","evidenceConflict"].contains(reason)) else { throw BrowserControlStateError.malformed }
            if verified || hasAlias {
                guard !(state == "active" || reason == "callEnded") || sourceDocument != nil,
                      state != "unknown" || generation == nil else { throw BrowserControlStateError.malformed }
            }
            return .init(tabID:tab,url:url,document:document,remoteAudio:remote,state:state,reason:reason,site:site,generation:generation,sourceDocument:sourceDocument)
        }
        return .init(instance:instance,sequence:sequence,tabs:tabs)
    }
}

/// Serialized on the control queue with snapshot commit, reservations and manual Stop.
/// The transport orders facts; it never forms part of a stable call identity.
struct SignalCallPolicy: Sendable {
    struct Key: Hashable, Sendable {
        let instance: String; let tab: Int; let document: String; let generation: String
        var sourceDocument: String? = nil
        static func == (a: Self, b: Self) -> Bool { a.tab == b.tab && SignalCallPolicy.exact(a.instance,b.instance) && SignalCallPolicy.exact(a.document,b.document) && SignalCallPolicy.exact(a.generation,b.generation) && SignalCallPolicy.exact(a.sourceDocument,b.sourceDocument) }
        func hash(into h: inout Hasher) { h.combine(Data(instance.utf8)); h.combine(tab); h.combine(Data(document.utf8)); h.combine(Data(generation.utf8)); h.combine(sourceDocument.map { Data($0.utf8) }) }
    }
    struct Suppression: Hashable, Sendable {
        let instance: String; let tab: Int; let generation: String
        static func == (a: Self, b: Self) -> Bool { a.tab == b.tab && SignalCallPolicy.exact(a.instance,b.instance) && SignalCallPolicy.exact(a.generation,b.generation) }
        func hash(into h: inout Hasher) { h.combine(Data(instance.utf8)); h.combine(tab); h.combine(Data(generation.utf8)) }
    }
    static func exact(_ a: String?, _ b: String?) -> Bool { a.map { Data($0.utf8) } == b.map { Data($0.utf8) } }
    struct Association: Sendable { let site: String; var lostAt: TimeInterval?; var lastExpiry: TimeInterval? }
    struct Peer: Sendable { let id: UUID; let order: UInt64; let snapshot: BrowserCallSignalSnapshot; var active: Set<Key>? = nil; var expiredAt: [Key:TimeInterval] = [:] }
    private struct Observation { let id: UUID; let sequence: Int; let active: Set<Key>?; let expiredAt: [Key:TimeInterval] }
    private var activeKeys: [Data:Set<Key>] = [:]
    static let grace: TimeInterval = 120
    private(set) var calls: [Key:Association] = [:]
    private(set) var snapshots: [Data:BrowserCallSignalSnapshot] = [:]
    private var owners: [Data:(UUID,UInt64)] = [:]
    private var suppressed: Set<Suppression> = []
    private var admitting: Key?
    private(set) var reservation: UUID?
    private(set) var started = false
    private(set) var retiring: CaptureEndReason?
    private var observed: [Data:Observation] = [:]
    var eligible: Bool {
        if !started, let admitting { return calls[admitting].map { $0.lostAt == nil } ?? false }
        return calls.values.contains { $0.lostAt == nil }
    }
    private var firstEligible: (key: Key, value: Association)? {
        calls.filter { $0.value.lostAt == nil }.sorted { String(describing:$0.key) < String(describing:$1.key) }.first
    }
    var site: String? { firstEligible?.value.site }
    var pendingCall: Key? { admitting }
    func owns(instance: String, tab: Int, generation: String?) -> Bool {
        calls.keys.contains { Self.exact($0.instance,instance) && $0.tab == tab && (generation == nil || Self.exact($0.generation,generation)) }
    }
    mutating func update(_ peers: [Peer], now: TimeInterval) {
        // Keep the greatest connection order even after it disconnects: stale live peers
        // can neither reclaim a profile nor replay its old active/end snapshot.
        for peer in peers.sorted(by:{ $0.order < $1.order }) {
            let instance = Data(peer.snapshot.instance.utf8)
            if let owner = owners[instance], owner.1 > peer.order { continue }
            if owners[instance]?.0 != peer.id {
                owners[instance] = (peer.id,peer.order); snapshots.removeValue(forKey:instance); observed.removeValue(forKey:instance)
                lose(instance,now:now)
            }
            guard observed[instance]?.id != peer.id || observed[instance]?.sequence != peer.snapshot.sequence || observed[instance]?.active != peer.active else { continue }
            observed[instance] = .init(id:peer.id,sequence:peer.snapshot.sequence,active:peer.active,expiredAt:peer.expiredAt)
            activeKeys[instance] = peer.active
            snapshots[instance] = peer.snapshot
            for key in Array(calls.keys) where Data(key.instance.utf8) == instance {
                let row = peer.snapshot.tabs.first { $0.tabID == key.tab }
                let same = Self.exact(row?.document,key.document) && Self.exact(row?.generation,key.generation) && Self.exact(row?.sourceDocument,key.sourceDocument)
                let active = row.map { value in peer.active?.contains(.init(instance:peer.snapshot.instance,tab:value.tabID,document:value.document,generation:value.generation ?? "",sourceDocument:value.sourceDocument)) ?? true } ?? false
                // The current profile/tab/generation identifies a positive end across
                // reloads too: retire lost predecessors as well as the current alias.
                if row?.state == "inactive" && row?.reason == "callEnded" && Self.exact(row?.generation,key.generation) { drop(key,reason:.callEnded) }
                else if let row, row.state == "active", active, !Self.exact(row.generation,key.generation) { drop(key,reason:.callEnded) }
                else if same && row?.state == "active" && active && (started || row?.remoteAudio == "mixed") {
                    calls[key]?.lostAt = nil
                    if let expiry = peer.expiredAt[key] { calls[key]?.lastExpiry = expiry }
                }
                else if calls[key]?.lostAt == nil {
                    let lostAt = min(now,calls[key]?.lastExpiry ?? peer.expiredAt[key] ?? now)
                    calls[key]?.lostAt = lostAt
                }
            }
        }
        for (instance,owner) in owners where !peers.contains(where:{ $0.id == owner.0 }) {
            snapshots.removeValue(forKey:instance); observed.removeValue(forKey:instance); lose(instance,now:now)
        }
        for profile in Array(owners.keys) {
            guard !peers.contains(where:{ Data($0.snapshot.instance.utf8) == profile }),
                  !calls.keys.contains(where:{ Data($0.instance.utf8) == profile }),
                  !suppressed.contains(where:{ Data($0.instance.utf8) == profile }) else { continue }
            owners.removeValue(forKey:profile); observed.removeValue(forKey:profile); activeKeys.removeValue(forKey:profile)
        }
        // Grace protects a running recording, never permission/input work that
        // has not opened yet. Fresh evidence may make a later new reservation.
        if reservation != nil && !started && !eligible { retiring = retiring ?? .pageGone }
    }
    private mutating func lose(_ instance: Data, now: TimeInterval) {
        for key in Array(calls.keys) where Data(key.instance.utf8) == instance && calls[key]?.lostAt == nil {
            let lostAt = min(now,calls[key]?.lastExpiry ?? now)
            calls[key]?.lostAt = lostAt
        }
    }
    private mutating func drop(_ key: Key, reason: CaptureEndReason) {
        calls.removeValue(forKey:key)
        if reservation != nil && (calls.isEmpty || !started && admitting == key) { retiring = retiring ?? reason }
    }
    mutating func advance(now: TimeInterval, enabled: Bool, blocked: (String,BrowserCallSignal) -> Bool = { _,_ in false }) {
        for (key,call) in calls where call.lostAt.map({ now - $0 >= Self.grace }) == true { drop(key,reason:.pageGone) }
        if !enabled && reservation != nil && !started { retiring = retiring ?? .user }
        guard retiring == nil, enabled else { return }
        for (_,snapshot) in snapshots {
            let instance = snapshot.instance
            for row in snapshot.tabs where row.eligible {
                guard let generation = row.generation, let site = row.site,
                      !suppressed.contains(.init(instance:instance,tab:row.tabID,generation:generation)), !blocked(instance,row) else { continue }
                let key = Key(instance:instance,tab:row.tabID,document:row.document,generation:generation,sourceDocument:row.sourceDocument)
                guard activeKeys[Data(instance.utf8)]?.contains(key) ?? true else { continue }
                if calls[key] == nil { calls[key] = .init(site:site,lastExpiry:observed[Data(instance.utf8)]?.expiredAt[key]) }
            }
        }
    }
    mutating func suppress(reason: CaptureEndReason = .user) {
        // Stop fences committed facts that have not reached admission, including while
        // there is no capture, or a previous capture is draining (GNOME #263).
        for (_,snapshot) in snapshots {
            let instance = snapshot.instance
            for row in snapshot.tabs where row.eligible {
                if let generation = row.generation { suppressed.insert(.init(instance:instance,tab:row.tabID,generation:generation)) }
            }
        }
        for key in calls.keys { suppressed.insert(.init(instance:key.instance,tab:key.tab,generation:key.generation)) }
        calls.removeAll()
        if reservation != nil { retiring = reason }
        let current = Set(snapshots.values.flatMap { snapshot in snapshot.tabs.compactMap { row in row.generation.map { Suppression(instance:snapshot.instance,tab:row.tabID,generation:$0) } } })
        for stale in suppressed.subtracting(current) where suppressed.count > 1024 { suppressed.remove(stale) }
    }
    mutating func reserve() -> UUID? {
        guard reservation == nil, retiring == nil, let first = firstEligible else { return nil }
        let id = UUID(); reservation = id; admitting = first.key; return id
    }
    func mayOpen(_ id: UUID) -> Bool { reservation == id && retiring == nil && (started || eligible) }
    mutating func didStart(_ id: UUID) { if reservation == id { started = true; admitting = nil } }
    mutating func release(_ id: UUID, failed: Bool) {
        guard reservation == id else { return }
        if failed { suppress() }
        reservation = nil; admitting = nil; started = false; retiring = nil
    }
}

public enum BrowserSignalAction: Sendable {
    case start(id: UUID, site: String, microphone: Bool)
    case stop(id: UUID, reason: CaptureEndReason)
}

/// A driver-open transaction serialized with control evidence and Stop. A boolean
/// checked before permission completion leaves a race between that check and start.
public final class BrowserSignalInputGate: @unchecked Sendable {
    private let lock = NSLock()
    private var allowed = false
    private var opened = false
    private var expiresAt: TimeInterval?
    private var closesAt: TimeInterval?
    private let clock: @Sendable () -> TimeInterval
    init(clock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) { self.clock = clock }
    public var permits: Bool { lock.withLock { allowed && (closesAt.map { clock() < $0 } ?? true) && (opened || (expiresAt.map { clock() < $0 } ?? true)) } }
    public func cancel() { lock.withLock { allowed = false } }
    var hasOpened: Bool { lock.withLock { opened } }
    func update(_ allowed: Bool, expiresAt: TimeInterval? = nil, closesAt: TimeInterval? = nil) { lock.withLock { self.allowed = allowed; self.expiresAt = expiresAt; self.closesAt = closesAt } }
    func validate() throws {
        try lock.withLock {
            guard allowed, closesAt.map({ clock() < $0 }) ?? true, opened || (expiresAt.map({ clock() < $0 }) ?? true) else { throw CancellationError() }
        }
    }
    func acceptOwner() throws {
        try lock.withLock {
            guard allowed, closesAt.map({ clock() < $0 }) ?? true, opened || (expiresAt.map({ clock() < $0 }) ?? true) else { throw CancellationError() }
            opened = true
        }
    }
    @MainActor func admit(_ body: () throws -> Void) throws {
        try lock.withLock {
            guard allowed, closesAt.map({ clock() < $0 }) ?? true, opened || (expiresAt.map({ clock() < $0 }) ?? true) else { throw CancellationError() }
            try body(); opened = true
        }
    }
}

/// Retained across asynchronous startup and UI retirement, so cancellation cannot
/// become a device failure and each reservation is released at most once.
@MainActor public final class BrowserSignalStartup {
    public private(set) var cancelled = false
    private var released = false
    public init() {}
    public func cancel() { cancelled = true }
    public func isCancelled(mayOpen: Bool, ending: Bool, shuttingDown: Bool) -> Bool {
        cancelled || !mayOpen || ending || shuttingDown
    }
    public func releaseFailure(failed: Bool, mayOpen: Bool, ending: Bool, shuttingDown: Bool) -> Bool? {
        guard !released else { return nil }
        released = true
        return failed && !isCancelled(mayOpen:mayOpen,ending:ending,shuttingDown:shuttingDown)
    }
}
