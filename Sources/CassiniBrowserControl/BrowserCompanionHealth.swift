// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import CassiniKit

/// Optional extension diagnostics never grant recording capabilities. A missing or
/// malformed self-check is unknown; only an explicit false blocks setup.
public struct BrowserCompanionDiagnostics: Equatable, Sendable {
    public private(set) var extensionVersion: String?
    public private(set) var extensionInstance: String?
    public private(set) var installType: String?
    public private(set) var filesOk: Bool?
    public var filesMissing: Bool { filesOk == false }
    public init() { }
    mutating func update(_ raw: JSON?) {
        guard let raw, raw.object != nil else { return }
        let version = Self.text(raw["extensionVersion"],limit:80)
        let instance = Self.text(raw["extensionInstance"],limit:128)
        if let instance, let previous = extensionInstance, instance != previous {
            self = .init()
        } else if let version, let previous = extensionVersion, version != previous {
            self = .init()
        }
        if raw["extensionVersion"] != nil { extensionVersion = version }
        if raw["extensionInstance"] != nil { extensionInstance = instance }
        if raw["installType"] != nil { installType = Self.text(raw["installType"],limit:80) }
        if raw["filesOk"] != nil { filesOk = raw["filesOk"]?.bool }
    }
    static func text(_ value: JSON?, limit: Int) -> String? {
        guard let text = value?.string, !text.isEmpty, text.unicodeScalars.count <= limit,
              !text.unicodeScalars.contains(where:{ CharacterSet.controlCharacters.contains($0) }) else { return nil }
        return text
    }
    public func isOlder(than bundled: String) -> Bool {
        func parts(_ value: String) -> [UInt64]? {
            let fields = value.split(separator:".",omittingEmptySubsequences:false)
            guard (1...4).contains(fields.count), fields.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy({ (48...57).contains($0) }) }) else { return nil }
            let result = fields.compactMap { UInt64($0) }
            return result.count == fields.count ? result : nil
        }
        guard let version = extensionVersion, let current = parts(version), let expected = parts(bundled) else { return false }
        for index in 0..<max(current.count,expected.count) {
            let left = index < current.count ? current[index] : 0, right = index < expected.count ? expected[index] : 0
            if left != right { return left < right }
        }
        return false
    }
}

public struct BrowserTabHealth: Equatable, Sendable {
    public enum Readiness: String, Sendable { case checking, ready, reloadRequired }
    public let key: BrowserMeetingKey
    public let state: Readiness
    public let hookSeen: Bool?
    public let relayAlive: Bool?
    public let message: String?
    public let canReload: Bool
}

public struct BrowserCompanionHealth: Equatable, Sendable {
    public enum State: String, Sendable { case idle, checking, ready, reloadRequired }
    public enum Connection: String, Sendable { case connected, disconnected }
    public let state: State
    public let nativeControl: Connection?
    public let workerReady: Bool
    public let tabs: [BrowserTabHealth]
    /// Global idle and unknown data never manufacture a broken meeting warning.
    public var reloadTabs: [BrowserTabHealth] { state == .idle ? [] : tabs.filter { $0.state == .reloadRequired && $0.canReload } }
    static func read(_ raw: JSON?, peer: UUID) -> Self? {
        guard let raw, raw.object != nil, let state = raw["state"]?.string.flatMap(State.init(rawValue:)),
              let rows = raw["tabs"]?.array, rows.count <= 100 else { return nil }
        var tabs: [BrowserTabHealth] = [], seen: Set<Int> = []
        for row in rows {
            guard let id = row["tabId"]?.int, (0...9_007_199_254_740_991).contains(id), seen.insert(id).inserted,
                  let readiness = row["state"]?.string.flatMap(BrowserTabHealth.Readiness.init(rawValue:)) else { return nil }
            tabs.append(.init(key:.init(peer:peer,tabID:id),state:readiness,hookSeen:row["hookSeen"]?.bool,relayAlive:row["relayAlive"]?.bool,
                              message:BrowserCompanionDiagnostics.text(row["message"],limit:2000),
                              canReload:readiness == .reloadRequired && row["action"]?.string == "reloadMeetingTab"))
        }
        return .init(state:state,nativeControl:raw["nativeControl"]?.string.flatMap(Connection.init(rawValue:)),workerReady:raw["worker"]?.string == "ready",tabs:tabs)
    }
}

public extension BrowserControlPeerSnapshot {
    /// Reload advice is actionable only on this capable peer's non-recording tabs.
    var reloadTabs: [BrowserTabHealth] {
        guard supportsTabReadiness, let browserHealth else { return [] }
        let active = Set(captures.map(\.key))
        return browserHealth.reloadTabs.filter { !active.contains($0.key) }
    }
}

/// Setup completion is stricter than recording capability admission. Diagnostics
/// never disable Start; an explicit file failure in any connected profile blocks
/// Done, while legacy or pending self-check diagnostics remain non-blocking.
public struct BrowserCompanionSetupHealth: Sendable {
    public let peers: [BrowserControlPeerSnapshot]
    public init(peers: [BrowserControlPeerSnapshot]) { self.peers = peers.filter(\.reconciled) }
    public var complete: Bool { !peers.isEmpty && peers.allSatisfy(\.setupComplete) }
    public var reloadTabs: [BrowserTabHealth] { peers.flatMap(\.reloadTabs) }
}
