// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Fixture-only sample clock. Repeating Dispatch timers round fractional
/// nanoseconds; an early wake must rearm the same boundary, not skip a packet.
struct SpectrogramFixtureClock {
    let chunk: Int
    init(chunk: Int) { precondition(chunk > 0); self.chunk = chunk }
    func completeFrames(at elapsed: Double) -> Int {
        Int(max(0,elapsed)*48000)/chunk*chunk
    }
    /// Yield after bounded work, without discarding any generated sample. A
    /// delayed timer rearms immediately until every completed chunk is offered.
    func batchEnd(after frames: Int, at elapsed: Double, maximumChunks: Int = 10) -> Int {
        precondition(maximumChunks > 0)
        return min(completeFrames(at:elapsed),frames + maximumChunks*chunk)
    }
    func nextDelay(after frames: Int, elapsed: Double) -> Double {
        max(0,Double(frames+chunk)/48000-elapsed)
    }
}
