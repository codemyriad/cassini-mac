// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// D7 Q5: protect a reserve even when the file writer itself could still append.
public struct DiskBudget: Equatable, Sendable {
    public let reserve: UInt64
    public let minutesLeft: Int?
    public let shouldStop: Bool
    public init(total: UInt64, free: UInt64, bytesPerSecond: Double) {
        reserve = max(1 << 30, total / 50)
        shouldStop = free <= reserve
        let usable = free > reserve ? free - reserve : 0
        if bytesPerSecond.isFinite && bytesPerSecond > 0 {
            minutesLeft = Int(min(Double(Int.max), floor(Double(usable) / bytesPerSecond / 60)))
        } else { minutesLeft = shouldStop ? 0 : nil }
    }
}
