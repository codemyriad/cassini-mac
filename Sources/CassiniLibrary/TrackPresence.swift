// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// D52.2 presence: span extent minus every stored gap range, intersected with
/// othersSource ownership. It never reads PCM (zeros are present). A missing/null
/// `gaps` or an `overflow` marker makes the affected time unknown.
public enum TrackPresence {
    public struct Gap: Sendable, Equatable {
        public let atMs: Double, durationMs: Double?, frames: UInt64?, kind: String
        public init(atMs: Double, durationMs: Double?, frames: UInt64?, kind: String) { self.atMs = atMs; self.durationMs = durationMs; self.frames = frames; self.kind = kind }
    }
    public typealias Window = (start: Double, end: Double)
    /// Present and unknown windows in session milliseconds.
    public static func windows(startOffsetMs: Double, sampleRate: Int, frames: UInt64, gaps: [Gap]?, ownership: [Window]? = nil) -> (present: [Window], unknown: [Window]) {
        let end = startOffsetMs + Double(frames)*1000/Double(max(1,sampleRate))
        guard end > startOffsetMs else { return ([],[]) }
        func clip(_ windows: [Window]) -> [Window] {
            guard let ownership else { return windows }
            return windows.flatMap { w in ownership.compactMap { o -> Window? in
                let a = max(w.start,o.start), b = min(w.end,o.end); return b > a ? (a,b) : nil } }
        }
        guard let gaps else { return ([],clip([(startOffsetMs,end)])) }
        let overflow = gaps.first { $0.kind == "overflow" }?.atMs
        let knownEnd = min(end,overflow ?? end)
        var present: [Window] = knownEnd > startOffsetMs ? [(startOffsetMs,knownEnd)] : []
        for gap in gaps where gap.kind != "overflow" {
            let length = gap.frames.map { Double($0)*1000/Double(max(1,sampleRate)) } ?? gap.durationMs ?? 0
            let a = gap.atMs, b = gap.atMs + length
            guard b > a else { continue }
            present = present.flatMap { w -> [Window] in
                guard a < w.end, b > w.start else { return [w] }
                return [(w.start,a),(b,w.end)].filter { $0.1 > $0.0 }
            }
        }
        let unknown: [Window] = knownEnd < end ? [(max(startOffsetMs,knownEnd),end)] : []
        return (clip(present),clip(unknown))
    }
    /// A window [a,b) ms covers 16 kHz session samples [ceil(16a-1e-6), ceil(16b-1e-6)).
    public static func samples16k(_ windows: [Window]) -> [Range<Int>] {
        var result: [Range<Int>] = []
        for w in windows.sorted(by:{ $0.start < $1.start }) {
            let a = Int((16*w.start - 1e-6).rounded(.up)), b = Int((16*w.end - 1e-6).rounded(.up))
            guard b > a else { continue }
            if let last = result.last, last.upperBound >= a { result[result.count-1] = last.lowerBound..<max(last.upperBound,b) } else { result.append(a..<b) }
        }
        return result
    }
}
