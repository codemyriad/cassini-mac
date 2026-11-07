// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Only raster boundaries matter to the picture. Retain one baseline before
/// the longest visible history (including the 2 s display delay), then at most
/// one transition per 20 ms boundary. The recording's full events stay intact.
public struct SpectrogramCaptureSelection {
    public struct Transition {
        let atMs: Double, me: Bool, others: Bool
        public init(atMs: Double, me: Bool, others: Bool) {
            self.atMs = atMs; self.me = me; self.others = others
        }
    }
    private struct Edge { let slot: Double, flags: UInt8 }
    private let initial: Edge
    private var edges: [Edge]
    public init(me: Bool = true, others: Bool = true) {
        let edge = Edge(slot: 0, flags: (me ? 1 : 0) | (others ? 2 : 0))
        initial = edge; edges = [edge]
    }
    public var storageBytes: Int { edges.capacity * MemoryLayout<Edge>.stride }
    var retainedTransitions: Int { edges.count }

    /// The live writer supplies ordered events. Invalid or backwards entries
    /// are ignored; unexpectedly distant future events cannot grow the view.
    public mutating func update<S: Sequence>(_ events: S, nowMs: Double) where S.Element == Transition {
        guard nowMs.isFinite, nowMs >= 0 else { return }
        let oldest = floor(max(0,nowMs-6240)/20)
        var baseline = initial, recent: [Edge] = []
        var previous = -Double.infinity
        for event in events {
            guard event.atMs.isFinite, event.atMs >= 0 else { continue }
            let slot = ceil(event.atMs/20)
            guard slot >= previous else { continue }; previous = slot
            let edge = Edge(slot: slot, flags: (event.me ? 1 : 0) | (event.others ? 2 : 0))
            if slot <= oldest { baseline = edge }
            else if recent.last?.slot == slot { recent[recent.count-1] = edge }
            else if recent.count < 400 { recent.append(edge) }
        }
        edges = [baseline]; edges.append(contentsOf: recent)
    }
    public func selected(_ lane: SpectrogramLane, slot: Int64) -> Bool {
        var low = 0, high = edges.count
        while low < high {
            let middle = (low+high)/2
            if edges[middle].slot <= Double(slot) { low = middle+1 } else { high = middle }
        }
        return edges[max(0,low-1)].flags & (lane == .me ? 1 : 2) != 0
    }
}
