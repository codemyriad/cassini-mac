// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

struct BrowserCallIdentity: Hashable, Sendable {
    let instance: BrowserInstance
    let tabID: Int
    let url: String
    static func == (a: Self, b: Self) -> Bool {
        a.instance == b.instance && a.tabID == b.tabID && Data(a.url.utf8) == Data(b.url.utf8)
    }
    func hash(into hasher: inout Hasher) {
        hasher.combine(instance); hasher.combine(tabID); hasher.combine(Data(url.utf8))
    }
}

/// Only explicit user intent crosses control connections. Attempts, automatic
/// stops and failed Starts remain per connection. No missing/wildcard URL exists.
struct UserStoppedCalls: Sendable {
    static let limit = 256
    static let retention: TimeInterval = 600
    static let reportWindow: TimeInterval = 10
    private struct Entry: Sendable { let call: BrowserCallIdentity; var touched: TimeInterval; let order: UInt64 }
    struct RetirementOwner: Hashable, Sendable { let connection: UUID; let lineage: UUID }
    private struct Retirement: Sendable {
        let entry: Entry
        var owner: RetirementOwner
        let maximumReplacementOrder: UInt64
    }
    private var retired: [BrowserCallIdentity:Retirement] = [:]
    private var entries: [BrowserCallIdentity:Entry] = [:]
    private var order: UInt64 = 0
    var count: Int { entries.count }
    var retainedCount: Int { entries.count + retired.count }
    var retirementConnections: Set<UUID> { Set(retired.values.map { $0.owner.connection }) }
    mutating func expire(now: TimeInterval, priorLive: Set<BrowserCallIdentity>, alive: (BrowserInstance) -> Bool?) {
        // Expire using the PRIOR inventory. Incoming discovery must never revive
        // a record which expired while its control link was absent.
        entries = entries.filter { _,entry in
            alive(entry.call.instance) != false && (priorLive.contains(entry.call) || now-entry.touched < Self.retention)
        }
        retired = retired.filter { _,value in
            alive(value.entry.call.instance) != false && (priorLive.contains(value.entry.call) || now-value.entry.touched < Self.retention)
        }
        for (slot,var value) in retired where priorLive.contains(value.entry.call) {
            let entry = value.entry
            value = .init(entry:.init(call:entry.call,touched:now,order:entry.order),owner:value.owner,maximumReplacementOrder:value.maximumReplacementOrder)
            retired[slot] = value
        }
        for (slot,var entry) in entries where priorLive.contains(entry.call) {
            entry.touched = now; entries[slot] = entry
        }
    }
    mutating func remember(_ call: BrowserCallIdentity, now: TimeInterval) {
        order &+= 1
        entries[call] = .init(call:call,touched:now,order:order)
        retired.removeValue(forKey:call)
        bound()
    }
    private mutating func bound() {
        while retainedCount > Self.limit {
            let candidates = Array(entries.values) + retired.values.map(\.entry)
            guard let oldest = candidates.min(by:{
                $0.touched == $1.touched ? $0.order < $1.order : $0.touched < $1.touched
            })?.call else { return }
            entries.removeValue(forKey:oldest); retired.removeValue(forKey:oldest)
        }
    }
    mutating func forget(_ call: BrowserCallIdentity) {
        // Explicit Record cancels both the live Stop and any possible rollback.
        entries.removeValue(forKey:call); retired.removeValue(forKey:call)
    }
    mutating func resolveLineage(_ owner: RetirementOwner, superseded: Bool, now: TimeInterval, provingOrder: UInt64 = 0) {
        // A provisional lineage can merge before this connection is superseded.
        // Retag its retirements so a subsequent replacement resolves them too.
        for key in Array(retired.keys) where retired[key]?.owner.connection == owner.connection {
            retired[key]?.owner = owner
        }
        guard superseded else { return }
        for (call,value) in retired where value.owner == owner && provingOrder <= value.maximumReplacementOrder {
            retired.removeValue(forKey:call)
            guard now-value.entry.touched < Self.retention else { continue }
            if entries[call].map({ $0.order < value.entry.order }) ?? true { entries[call] = value.entry }
        }
    }
    private mutating func retire(_ call: BrowserCallIdentity, by owner: RetirementOwner?, maximumReplacementOrder: UInt64) {
        guard let entry = entries.removeValue(forKey:call), let owner else { return }
        retired[call] = .init(entry:entry,owner:owner,maximumReplacementOrder:maximumReplacementOrder)
    }
    func contains(_ call: BrowserCallIdentity) -> Bool {
        entries[call] != nil
    }
    mutating func update(_ call: BrowserCallIdentity, absentSince: TimeInterval?, mayRemove: Bool, now: TimeInterval, retiredBy: RetirementOwner? = nil, maximumReplacementOrder: UInt64 = .max) {
        if mayRemove {
            for key in Array(entries.keys) where key.instance == call.instance && key.tabID == call.tabID && key != call {
                retire(key,by:retiredBy,maximumReplacementOrder:maximumReplacementOrder)
            }
        }
        guard var entry = entries[call] else { return }
        // Initial discovery can be arbitrarily slow. Only an inventory that
        // previously established presence and then absence starts this clock.
        if mayRemove, let absentSince, min(now-absentSince,now-entry.touched) >= Self.reportWindow {
            retire(call,by:retiredBy,maximumReplacementOrder:maximumReplacementOrder); return
        }
        entry.touched = now; entries[call] = entry
    }
}
