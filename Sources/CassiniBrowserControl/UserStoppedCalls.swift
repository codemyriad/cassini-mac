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
    private var entries: [BrowserCallIdentity:Entry] = [:]
    private var order: UInt64 = 0
    var count: Int { entries.count }
    mutating func expire(now: TimeInterval, priorLive: Set<BrowserCallIdentity>, alive: (BrowserInstance) -> Bool?) {
        // Expire using the PRIOR inventory. Incoming discovery must never revive
        // a record which expired while its control link was absent.
        entries = entries.filter { _,entry in
            alive(entry.call.instance) != false && (priorLive.contains(entry.call) || now-entry.touched < Self.retention)
        }
        for (slot,var entry) in entries where priorLive.contains(entry.call) {
            entry.touched = now; entries[slot] = entry
        }
    }
    mutating func remember(_ call: BrowserCallIdentity, now: TimeInterval) {
        order &+= 1
        entries[call] = .init(call:call,touched:now,order:order)
        if entries.count > Self.limit, let oldest = entries.min(by:{
            $0.value.touched == $1.value.touched ? $0.value.order < $1.value.order : $0.value.touched < $1.value.touched
        })?.key {
            entries.removeValue(forKey:oldest)
        }
    }
    mutating func forget(_ call: BrowserCallIdentity) {
        entries.removeValue(forKey:call)
    }
    func contains(_ call: BrowserCallIdentity) -> Bool {
        entries[call] != nil
    }
    mutating func update(_ call: BrowserCallIdentity, absentSince: TimeInterval?, mayRemove: Bool, now: TimeInterval) {
        if mayRemove { entries = entries.filter { key,_ in key.instance != call.instance || key.tabID != call.tabID || key == call } }
        guard var entry = entries[call] else { return }
        // Initial discovery can be arbitrarily slow. Only an inventory that
        // previously established presence and then absence starts this clock.
        if mayRemove, let absentSince, min(now-absentSince,now-entry.touched) >= Self.reportWindow {
            entries.removeValue(forKey:call); return
        }
        entry.touched = now; entries[call] = entry
    }
}
