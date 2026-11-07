// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// One delay clock for both lanes. Inputs use the recorder's session clock;
/// presentation never substitutes Date or packet-arrival time for audio time.
public struct SpectrogramDisplayClock {
    public private(set) var delayMs: Double = 40
    private struct Arrival { let at: Double, lateness: Double }
    private var arrivals: [Arrival?] = [Arrival?](repeating:nil,count:1024)
    private var first = 0, count = 0
    // Maintain the exact order statistic as arrivals enter/leave the 3s window.
    // This avoids allocating and sorting the whole window every 100ms.
    private var lateness: [Double] = []
    private var lastTick: Double?
    private var lastArrival: Double = -.infinity
    private var nextTargetAt: Double = 0
    private var target: Double = 40
    public init() { lateness.reserveCapacity(1024) }
    public mutating func reset() { self = .init() }
    public mutating func observe(columnMs: Double, arrivalMs: Double) {
        guard columnMs.isFinite, arrivalMs.isFinite, arrivalMs >= 0, arrivalMs >= lastArrival else { return }
        lastArrival = arrivalMs
        evict(before:arrivalMs-3000)
        if count == arrivals.count { removeOldest() }
        let value = max(0,arrivalMs-columnMs)
        arrivals[(first+count)%arrivals.count] = .init(at:arrivalMs,lateness:value); count += 1
        lateness.insert(value,at:lowerBound(value))
    }
    /// Returns the page's audio time. A pill uses this minus 60 ms so its four
    /// 20 ms columns are complete before their 80 ms column appears.
    public mutating func advance(nowMs: Double) -> Double {
        guard nowMs.isFinite, nowMs >= 0 else { return 0 }
        guard lastTick == nil || nowMs >= lastTick! else { return lastTick!-delayMs }
        evict(before:nowMs-3000)
        if nowMs >= nextTargetAt {
            let p95 = lateness.isEmpty ? 0 : lateness[max(0,Int(ceil(Double(lateness.count)*0.95))-1)]
            target = min(2000,max(40,p95+20)); nextTargetAt = nowMs+100
        }
        if let lastTick {
            let elapsed = nowMs-lastTick
            if target > delayMs { delayMs = min(target,delayMs+elapsed*0.5) }
            else { delayMs = max(target,delayMs-elapsed*0.02) }
        }
        lastTick = nowMs
        return nowMs-delayMs
    }
    private mutating func evict(before oldest: Double) {
        while count > 0, let value = arrivals[first], value.at < oldest {
            removeOldest()
        }
    }
    private func lowerBound(_ value: Double) -> Int {
        var low = 0, high = lateness.count
        while low < high {
            let middle = (low+high)/2
            if lateness[middle] < value { low = middle+1 } else { high = middle }
        }
        return low
    }
    private mutating func removeOldest() {
        let value = arrivals[first]!.lateness
        lateness.remove(at:lowerBound(value))
        arrivals[first] = nil; first = (first+1)%arrivals.count; count -= 1
    }
}

/// Pool only the pill: retain a short syllable using the maximum of its four
/// time columns and each pair of frequency bands. An entirely missing group
/// remains a hole rather than being turned into recorded silence.
public enum SpectrogramPillPooling {
    public static func bands(_ columns: [[UInt8]?]) -> [UInt8]? {
        precondition(columns.count == 4)
        let present = columns.compactMap { $0 }
        guard !present.isEmpty else { return nil }
        precondition(present.allSatisfy { $0.count == SpectrogramParameters.bands })
        return (0..<16).map { band in present.reduce(UInt8(0)) { max($0,max($1[band*2],$1[band*2+1])) } }
    }
}
