// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// 5 ms lookahead/50 ms release, threshold 0.95. Prefetch compensates the
/// lookahead so output samples keep their source timeline. Memory is bounded.
struct PeakLimiter {
    private let lookahead = 240
    private let release = 1 - exp(-1.0 / 2400)
    private var gain = 1.0
    private var index: Int64 = 0
    private var samples: [Float] = []
    private var sampleHead = 0
    private var peaks: [(Int64,Float)] = []
    private var peakHead = 0
    mutating func feed(_ values: [Float]) throws -> [Float] {
        var output: [Float] = []; output.reserveCapacity(values.count)
        for value in values {
            guard value.isFinite else { throw MeetingExportError.invalidSource }
            samples.append(value)
            let peak = abs(value)
            while peaks.count > peakHead, peaks.last!.1 <= peak { peaks.removeLast() }
            peaks.append((index,peak))
            if index >= lookahead {
                let first = index - Int64(lookahead)
                while peakHead < peaks.count, peaks[peakHead].0 < first { peakHead += 1 }
                let maximum = Double(peaks[peakHead].1)
                let target = maximum > 0.95 ? 0.95 / maximum : 1
                gain = target < gain ? target : gain + (target - gain) * release
                output.append(Float(Double(samples[sampleHead]) * gain)); sampleHead += 1
            }
            index += 1
            if sampleHead >= 4096 { samples.removeFirst(sampleHead); sampleHead = 0 }
            if peakHead >= 4096 { peaks.removeFirst(peakHead); peakHead = 0 }
        }
        return output
    }
    mutating func finish() throws -> [Float] { try feed([Float](repeating:0,count:lookahead)) }
}
