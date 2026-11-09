// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import CassiniKit
import CassiniRecording

/// Three distinct, producer-bound namespaces; no cross-namespace string join.
public struct BrowserVerifiedCall: Hashable, Sendable {
    public let profile: String
    public let tab: Int
    public let browserDocument: String
    public let sourceDocument: String
    public let generation: String
    public static func == (a: Self, b: Self) -> Bool {
        a.tab == b.tab && [a.profile,a.browserDocument,a.sourceDocument,a.generation].map { Data($0.utf8) } ==
            [b.profile,b.browserDocument,b.sourceDocument,b.generation].map { Data($0.utf8) }
    }
    public func hash(into h: inout Hasher) {
        h.combine(tab)
        for value in [profile,browserDocument,sourceDocument,generation] { h.combine(Data(value.utf8)) }
    }
    static func read(profile: String, row: BrowserCallSignal) -> Self? {
        guard let source = row.sourceDocument, let generation = row.generation,
              [profile,row.document,source,generation].allSatisfy({ !$0.isEmpty && $0.utf8.count <= 200 }) else { return nil }
        return .init(profile:profile,tab:row.tabID,browserDocument:row.document,sourceDocument:source,generation:generation)
    }
    var signalKey: SignalCallPolicy.Key { .init(instance:profile,tab:tab,document:browserDocument,generation:generation,sourceDocument:sourceDocument) }
}

struct BrowserActiveProof: Sendable {
    static let lifetime: TimeInterval = 5
    let call: BrowserVerifiedCall
    let receivedAt: TimeInterval
    func fresh(at now: TimeInterval) -> Bool { now >= receivedAt && now-receivedAt < Self.lifetime }
}

/// Authorizes the app-managed independent native Start from its issued control
/// command. Verified peers require the exact issued ask. Legacy manual Starts
/// retain the unique call binding because their producer has no Start requestId. No I/O or device operation runs under this lock.
public final class BrowserAutomaticAdmissionStore: @unchecked Sendable {
    private struct Entry {
        let key: BrowserMeetingKey
        let browser: BrowserInstance?
        let generation: String?
        let document: String?
        let microphone: Bool
        let call: BrowserVerifiedCall?
        let gate: BrowserSignalInputGate?
        let verifiedConfigured: Bool
        var capture: String?
        var lastExpiry: TimeInterval?
        var lostAt: TimeInterval?
        var ending: CaptureEndReason?
    }
    private let lock = NSLock()
    private let clock: @Sendable () -> TimeInterval
    private var entries: [Data:Entry] = [:]
    public init(clock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) { self.clock = clock }
    func issue(_ request: BrowserControlRequest, browser: BrowserInstance?, generation: String?, document: String?, microphone: Bool,
               verifiedConfigured: Bool, deadline: TimeInterval?) throws {
        try lock.withLock {
            guard request.automaticCall == nil || verifiedConfigured else { throw BrowserIPCError.unavailable }
            guard entries.count < 1024 else { throw BrowserIPCError.unavailable }
            let gate = request.automaticCall.map { _ in BrowserSignalInputGate(clock:clock) }
            if gate != nil { guard let deadline, clock() < deadline else { throw CancellationError() }; gate?.update(true,expiresAt:deadline,closesAt:deadline+120) }
            entries[Data(request.id.utf8)] = .init(key:request.key,browser:browser,generation:generation,document:document,microphone:microphone,call:request.automaticCall,gate:gate,verifiedConfigured:verifiedConfigured,lastExpiry:deadline)
        }
    }
    func update(pending: [BrowserVerifiedCall:TimeInterval], owned: [BrowserVerifiedCall:TimeInterval], ended: Set<BrowserVerifiedCall>) {
        lock.withLock {
            let now = clock()
            for id in Array(entries.keys) {
                guard var entry = entries[id], let call = entry.call, let gate = entry.gate else { continue }
                if entry.ending != nil { gate.cancel(); continue }
                if !gate.hasOpened {
                    let deadline = pending[call]
                    gate.update(deadline.map { now < $0 } ?? false,expiresAt:deadline,closesAt:deadline.map { $0+120 })
                    if let deadline { entry.lastExpiry = deadline }
                } else {
                    if ended.contains(call) || owned.keys.contains(where:{ $0.tab == call.tab && SignalCallPolicy.exact($0.profile,call.profile) && $0 != call }) { entry.ending = .callEnded }
                    if let expiry = owned[call], now < expiry { entry.lastExpiry = expiry; entry.lostAt = nil }
                    else if entry.lostAt == nil { entry.lostAt = min(now,entry.lastExpiry ?? now) }
                    let deadline = entry.lostAt.map { $0+120 } ?? entry.lastExpiry.map { $0+120 }
                    if deadline.map({ now >= $0 }) == true { entry.ending = entry.ending ?? .pageGone }
                    gate.update(entry.ending == nil,closesAt:deadline)
                }
                entries[id] = entry
            }
        }
    }
    func authorize(_ info: BrowserAudioStart, browser: BrowserInstance?) throws -> BrowserAudioStart {
        try lock.withLock {
            func matches(_ entry: Entry) -> Bool {
                entry.capture == nil && entry.ending == nil && entry.browser == browser && entry.microphone == info.microphone &&
                    SignalCallPolicy.exact(entry.generation,info.callGeneration) && SignalCallPolicy.exact(entry.document,info.documentGeneration)
            }
            let id: Data
            if let request = info.requestID {
                // A present ID must match exactly, preserving JSON type and UTF-8 bytes.
                // Mac-issued IDs are strings; a number can never answer one.
                guard let text = request.string else { throw BrowserIPCError.unavailable }
                id = Data(text.utf8)
            } else {
                // Coordinator's legacy exception: automatic work is forbidden without
                // the v1 ACK. Only one pending legacy manual ask may match this packet.
                let candidates = entries.filter { _,entry in matches(entry) }
                guard candidates.count == 1, let candidate = candidates.first,
                      !candidate.value.verifiedConfigured, candidate.value.call == nil else { throw BrowserIPCError.unavailable }
                id = candidate.key
            }
            guard let entry = entries[id], matches(entry) else { throw BrowserIPCError.unavailable }
            try entry.gate?.validate()
            entries[id]?.capture = info.captureID
            return .init(captureID:info.captureID,timelineOriginMs:info.timelineOriginMs,microphone:info.microphone,
                         callGeneration:info.callGeneration,documentGeneration:info.documentGeneration,inputGate:entry.gate,automaticCall:entry.call,requestID:info.requestID)
        }
    }
    var pendingRequestCount: Int { lock.withLock { entries.values.filter { $0.capture == nil }.count } }
    func complete(_ id: String) {
        lock.withLock { if entries[Data(id.utf8)]?.capture == nil { entries.removeValue(forKey:Data(id.utf8))?.gate?.cancel() } }
    }
    func hasAcceptedInput(_ id: String) -> Bool { lock.withLock { entries[Data(id.utf8)]?.gate?.hasOpened == true } }
    func pendingWasWithdrawn(_ id: String) -> Bool { lock.withLock { entries[Data(id.utf8)]?.call != nil && entries[Data(id.utf8)]?.gate?.hasOpened == false && entries[Data(id.utf8)]?.gate?.permits == false } }
    func cancelAllPending(automaticOnly: Bool = false) {
        lock.withLock { for (id,var entry) in entries where (!automaticOnly || entry.call != nil) && (entry.capture == nil || entry.gate?.hasOpened == false) {
            entry.gate?.cancel()
            if entry.capture == nil { entries.removeValue(forKey:id) } else { entry.ending = .user; entries[id] = entry }
        } }
    }
    public func cancel(_ capture: String, reason: CaptureEndReason) {
        lock.withLock { for (id,var entry) in entries where entry.capture == capture { entry.ending = entry.ending ?? reason; entry.gate?.cancel(); entries[id] = entry } }
    }
    func cancel(_ key: BrowserMeetingKey, reason: CaptureEndReason) {
        lock.withLock { for (id,var entry) in entries where entry.key == key { entry.ending = entry.ending ?? reason; entry.gate?.cancel(); if entry.capture == nil { entries.removeValue(forKey:id) } else { entries[id] = entry } } }
    }
    public func retire(_ capture: String) { lock.withLock { for (id,entry) in entries where entry.capture == capture { entry.gate?.cancel(); entries.removeValue(forKey:id) } } }
    public func endReason(_ capture: String) -> CaptureEndReason? {
        lock.withLock {
            guard let entry = entries.values.first(where:{ $0.capture == capture && $0.call != nil }) else { return nil }
            if entry.gate?.hasOpened == false, entry.gate?.permits == false { return entry.ending ?? .pageGone }
            return entry.ending ?? ((entry.lostAt ?? entry.lastExpiry).map { clock() >= $0+120 } == true ? .pageGone : nil)
        }
    }
}
