// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// heartbeat-v1 (P11, D52.4): the app side of one control connection. The app pings,
/// the extension only answers. Times are monotonic milliseconds.
public struct ControlHeartbeat: Sendable {
    public static let interval: UInt64 = 10_000
    public static let lossAfter: UInt64 = 25_000
    public enum Event: Equatable, Sendable { case ping(UInt64), lost }
    private var negotiated = false, active = false, lost = false
    private var lastInbound: UInt64 = 0, lastPing: UInt64 = 0, sequence: UInt64 = 0
    public init() {}
    /// A hello opens the connection: nothing carries over. A hello without the
    /// capability is never pinged and never timed out.
    public mutating func hello(capabilities: [String], at now: UInt64) {
        self = .init(); negotiated = capabilities.contains("heartbeat-v1"); lastInbound = now
    }
    /// Every inbound frame counts. Pinging and the loss deadline start at the first status.
    public mutating func inbound(_ type: String?, at now: UInt64) {
        guard !lost else { return }
        lastInbound = now
        if type == "status", negotiated, !active { active = true; lastPing = now }
    }
    /// Loss is checked before pinging; after a loss the connection is gone.
    public mutating func tick(at now: UInt64) -> Event? {
        guard active, !lost else { return nil }
        if now >= lastInbound, now - lastInbound >= Self.lossAfter { lost = true; return .lost }
        guard now >= lastPing, now - lastPing >= Self.interval else { return nil }
        lastPing = now; sequence += 1
        return .ping(sequence - 1)
    }
}
