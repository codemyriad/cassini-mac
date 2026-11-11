// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// D36.2 (coordination e0e3124), with D36.3 (da65b18) raising case A drawing to 1.7%
/// and D36.4 (aa34676) the B/D worst frame to 100 ms (p95 17.5 ms stays the pacing guard):
/// hosted regression guards, not hardware targets. D88 applies the frame limits
/// to main-thread CPU between updates, never scheduler/WindowServer wall delays.
/// Both lanes share a 50 Hz timeline. Count its steady-state slots once, rather
/// than multiplying the allowed lateness by lane or source-track count.
enum SpectrogramHostedBudget {
    static func steadyColumns(seconds:Double)->Double {floor(seconds*50)}
    static func latePasses(mode:String,seconds:Double,late:UInt64)->Bool {
        let columns=steadyColumns(seconds:seconds)
        guard seconds.isFinite,columns>0 else { return false }
        return mode == "C" || mode == "E" ? late == 0 : Double(late)/columns <= 0.03
    }
    static func evaluate(mode:String,seconds:Double,analysis:Double,drawing:Double,
                         p95:Double,maximum:Double,frameCPUSamples:UInt64,late:UInt64,payload:Int)->[String:Bool] {
        let hidden=mode == "C" || mode == "E"
        let columns=steadyColumns(seconds:seconds)
        let valid=seconds.isFinite && columns>0
        return ["analysis":valid && (hidden ? analysis == 0 : analysis <= 0.8),
                "drawing":valid && drawing <= (mode == "A" ? 1.7 : 3.5),
                "frameWork":valid && (hidden || (frameCPUSamples > 0 && (mode == "A" || (p95 <= 17.5 && maximum <= 100)))),
                "late":latePasses(mode:mode,seconds:seconds,late:late),
                "logicalViewPayload":payload >= 0 && payload <= 131072]
    }
}

/// CPU cost per delivered media work, independent of hosted scheduler delays.
/// Input is one shared 48 kHz timeline, never multiplied by lane/track count.
struct SpectrogramMediaWork {
    let frames: Int
    var seconds: Double { Double(frames)/48000 }
    func corePercent(cpuSeconds: Double) -> Double {
        guard frames > 0, cpuSeconds.isFinite, cpuSeconds >= 0 else { return .infinity }
        return cpuSeconds/seconds*100
    }
}

/// Bounded probe-only histogram of main-thread work BETWEEN rendered updates.
/// Sampling the thread clock across updates includes implicit CA commits and other
/// main-thread work, while a process descheduled by the host consumes no CPU.
/// No wall clock enters these statistics. First update establishes the baseline.
struct SpectrogramFrameCPU {
    private var previous: UInt64?
    private var bins = [UInt64](repeating:0,count:512)
    private(set) var count: UInt64 = 0
    private(set) var maximumMs = 0.0
    private(set) var valid = true
    mutating func record(through nanoseconds: UInt64) {
        defer { previous = nanoseconds }
        guard let previous else { return }
        guard nanoseconds >= previous else { valid = false; return }
        let ms = Double(nanoseconds - previous)/1_000_000
        bins[min(511,Int(ceil(ms*10)))] += 1
        count += 1; maximumMs = max(maximumMs,ms)
    }
    var p95Ms: Double {
        guard count > 0 else { return 0 }
        let target = UInt64(ceil(Double(count)*0.95)); var sum: UInt64 = 0
        for (index,n) in bins.enumerated() { sum += n; if sum >= target { return Double(index)/10 } }
        return 51.1
    }
}
