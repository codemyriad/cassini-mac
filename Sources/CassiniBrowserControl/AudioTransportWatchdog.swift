// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// D52.4/D52.5 PCM_STALE_AFTER for one audio transport (SPEC.md "Audio transport
/// liveness"). Every audio-transport frame counts; control frames never reach it. It is
/// armed only while an open span (declared by `track`, not yet ended by `trackEnd` or
/// `stop`) has delivered PCM, and the transport is stale exactly when armed and
/// `now - lastFrame >= 45 s`. A frame arriving at or after that deadline is too late.
public struct AudioTransportWatchdog: Sendable {
    public static let staleAfter: UInt64 = 45_000
    public enum Frame: Sendable { case track(String), audio(String), trackEnd(String), stop, other }
    private var open: Set<String> = [], delivered: Set<String> = [], last: UInt64?
    public init() {}
    public var armed: Bool { !open.isDisjoint(with:delivered) }
    public func isStale(at now: UInt64) -> Bool {
        guard let last, armed, now >= last else { return false }
        return now - last >= Self.staleAfter
    }
    /// Records a frame; false when it arrived too late (the transport was already stale).
    public mutating func receive(_ frame: Frame, at now: UInt64) -> Bool {
        if isStale(at:now) { return false }
        last = now
        switch frame {
        case .track(let id): open.insert(id)
        case .audio(let id): if open.contains(id) { delivered.insert(id) }
        case .trackEnd(let id): open.remove(id)
        case .stop: open.removeAll()
        case .other: break
        }
        return true
    }
}
