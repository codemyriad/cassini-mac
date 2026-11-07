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
    private struct Pending { let slot: Int64; var tracks: UInt64 = 0; var powers = SIMD32<Float>.zero }
    // Ordered on insertion, so every release drains a prefix. No per-frame
    // dictionary scan, key array, sort or repeated hash lookup is necessary.
    private var pending: [Pending] = []
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
        var low = 0, high = pending.count
        while low < high {
            let middle = (low+high)/2
            if pending[middle].slot < slot { low = middle+1 } else { high = middle }
        }
        var index = low
        let existing = index < pending.count && pending[index].slot == slot
        if !existing, pending.count == Self.capacity {
            // Preserve the original overflow policy, including sparse slots
            // and out-of-order input: retain the most recent 128 columns.
            if index == 0 { overflow += 1; return }
            pending.removeFirst(); index -= 1; overflow += 1
        }
        var value = existing ? pending[index] : Pending(slot:slot)
        let bit = UInt64(1)<<trackIndex
        guard value.tracks & bit == 0 else { return }
        value.tracks |= bit
        for band in 0..<32 {
            let power = powers[band]
            value.powers[band] += power.isFinite ? Float(max(0,min(Double(Float.greatestFiniteMagnitude)/64,power))) : 0
        }
        if existing { pending[index] = value } else { pending.insert(value,at:index) }
    }
    /// Reuse a retired source's bounded index without discarding its pending
    /// power or treating a replacement as the same source in overlapping slots.
    func retire(trackIndex: Int) {
        precondition((0..<64).contains(trackIndex))
        let mask = ~(UInt64(1)<<trackIndex)
        for index in pending.indices { pending[index].tracks &= mask }
    }
    /// Missing slots produce no column: the renderer writes a transparent hole.
    /// SpectrogramRelease sees the discontinuity and cannot bridge it with ink.
    public func release(through slot: Int64, emit: (SpectrogramColumn) -> Void) {
        guard slot > releasedThrough else { return }
        var count = 0
        while count < pending.count && pending[count].slot <= slot {
            let value = pending[count]
            emit(.init(slot:value.slot,bands:release.column(slot:value.slot,powers:value.powers)))
            count += 1
        }
        if count > 0 { pending.removeFirst(count) }
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
