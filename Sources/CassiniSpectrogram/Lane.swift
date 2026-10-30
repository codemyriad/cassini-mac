// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import os

public enum SpectrogramLane: Int, Sendable { case me, others }
public struct SpectrogramColumn: Sendable, Equatable {
    public let slot: Int64
    public let bands: [UInt8]
    public init(slot: Int64, bands: [UInt8]) {
        precondition(slot >= 0 && bands.count == SpectrogramParameters.bands)
        self.slot = slot; self.bands = bands
    }
}

/// Serial analysis-queue state. Hold linear powers until the shared display
/// delay makes a slot due, so independently arriving remote tracks add before
/// the logarithm and release. Nothing here blocks a capture or writer queue.
public final class SpectrogramLaneAccumulator {
    private struct Pending { var tracks: UInt64 = 0; var powers = SIMD32<Float>.zero }
    private var pending: [Int64:Pending] = [:]
    private var release = SpectrogramRelease()
    public private(set) var releasedThrough: Int64 = -1
    public private(set) var late: UInt64 = 0
    public private(set) var overflow: UInt64 = 0
    public var pendingCount: Int { pending.count }
    public static let capacity = 128
    public init() {}
    public func reset() { pending.removeAll(keepingCapacity:true); release.reset(); releasedThrough = -1; late = 0; overflow = 0 }
    public func append(slot: Int64, trackIndex: Int, powers: [Double]) {
        precondition(slot >= 0 && (0..<64).contains(trackIndex) && powers.count == 32)
        guard slot > releasedThrough else { late += 1; return }
        if pending[slot] == nil, pending.count == Self.capacity {
            let oldest = pending.keys.min()!
            // Keep recent picture data; never grow or backpressure recording.
            if slot < oldest { overflow += 1; return }
            pending.removeValue(forKey:oldest); overflow += 1
        }
        var value = pending[slot] ?? Pending()
        let bit = UInt64(1)<<trackIndex
        guard value.tracks & bit == 0 else { return }
        value.tracks |= bit
        for band in 0..<32 {
            let power = powers[band]
            value.powers[band] += power.isFinite ? Float(max(0,min(Double(Float.greatestFiniteMagnitude)/64,power))) : 0
        }
        pending[slot] = value
    }
    /// Missing slots produce no column: the renderer writes a transparent hole.
    /// SpectrogramRelease sees the discontinuity and cannot bridge it with ink.
    public func release(through slot: Int64, emit: (SpectrogramColumn) -> Void) {
        guard slot > releasedThrough else { return }
        for key in pending.keys.filter({ $0 <= slot }).sorted() {
            let value = pending.removeValue(forKey:key)!
            emit(.init(slot:key,bands:release.column(slot:key,powers:(0..<32).map { Double(value.powers[$0]) })))
        }
        releasedThrough = slot
    }
}

/// One mailbox per session. A bounded ring under an unfair lock transfers
/// quantized columns; the display clock drains it without per-column wakeups.
public final class SpectrogramMailbox: @unchecked Sendable {
    public static let capacity = 64
    private struct Ring {
        var values = [SpectrogramColumn?](repeating:nil,count:SpectrogramMailbox.capacity)
        var first = 0, count = 0
        var dropped: UInt64 = 0
        mutating func push(_ value: SpectrogramColumn) {
            if count == values.count { values[first] = nil; first = (first+1)%values.count; count -= 1; dropped += 1 }
            values[(first+count)%values.count] = value; count += 1
        }
        mutating func drain() -> [SpectrogramColumn] {
            var result: [SpectrogramColumn] = []; result.reserveCapacity(count)
            while count > 0 {
                if let value = values[first] { result.append(value) }
                values[first] = nil; first = (first+1)%values.count; count -= 1
            }
            return result
        }
    }
    private struct Storage { var me = Ring(), others = Ring() }
    private let state = OSAllocatedUnfairLock(initialState:Storage())
    public init() {}
    public func append(_ column: SpectrogramColumn, lane: SpectrogramLane) {
        state.withLock { value in
            switch lane { case .me: value.me.push(column); case .others: value.others.push(column) }
        }
    }
    public struct Batch: Sendable {
        public let me: [SpectrogramColumn], others: [SpectrogramColumn]
        public let droppedMe: UInt64, droppedOthers: UInt64
    }
    public func drain() -> Batch {
        state.withLock { value in
            .init(me:value.me.drain(),others:value.others.drain(),droppedMe:value.me.dropped,droppedOthers:value.others.dropped)
        }
    }
    public func reset() { state.withLock { $0 = Storage() } }
}
