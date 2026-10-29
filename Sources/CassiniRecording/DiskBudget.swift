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
            let minutes = floor(Double(usable) / bytesPerSecond / 60)
            minutesLeft = minutes >= Double(Int.max) ? Int.max : Int(minutes)
        } else { minutesLeft = shouldStop ? 0 : nil }
    }
}

/// Track each folder independently so removing one capture does not reset the
/// others' rates. Callers sum these by filesystem volume before budgeting free
/// space; two concurrent meetings must not each assume exclusive disk use.
public struct CaptureWriteRates: Sendable {
    private var previous: [UUID:(TimeInterval,UInt64)] = [:]
    public init() {}
    public mutating func observe(bytes: [UUID:UInt64], at uptime: TimeInterval, initialRates: [UUID:Double] = [:]) -> [UUID:Double] {
        var rates: [UUID:Double] = [:]
        for (id,count) in bytes {
            if let (before,old) = previous[id], count >= old, uptime.isFinite, uptime > before {
                rates[id] = Double(count-old)/max(0.1,uptime-before)
            } else { rates[id] = max(0,initialRates[id] ?? 0) }
        }
        previous = bytes.mapValues { (uptime,$0) }
        return rates
    }
}
