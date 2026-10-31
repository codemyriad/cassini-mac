// SPDX-License-Identifier: GPL-3.0-or-later
import Testing
import Foundation
@testable import CassiniSpectrogram

@Suite struct LaneTests {
    @Test func replacementInTheSamePendingSlotKeepsBothPowers() {
        let lane = SpectrogramLaneAccumulator()
        let power = [Double](repeating:1e-4,count:32)
        lane.append(slot:1,trackIndex:0,powers:power)
        lane.retire(trackIndex:0)
        lane.append(slot:1,trackIndex:0,powers:power)
        var columns: [SpectrogramColumn] = []
        lane.release(through:1) { columns.append($0) }
        #expect(columns.map(\.bands) == [SpectrogramRelease.raw(powers:power.map { $0*2 })])
    }
    @Test func independentTracksSumBeforeTheLogarithmAndDuplicatesDoNotDoubleCount() {
        let lane = SpectrogramLaneAccumulator(), power = [Double](repeating:1e-4,count:32)
        lane.append(slot:10,trackIndex:1,powers:power)
        lane.append(slot:10,trackIndex:1,powers:power)
        lane.append(slot:10,trackIndex:2,powers:power)
        var output: [SpectrogramColumn] = []
        lane.release(through:10) { output.append($0) }
        let expected = SpectrogramRelease.raw(powers:power.map { $0*2 })
        #expect(output == [.init(slot:10,bands:expected)])
        #expect(abs(10*log10(2)-3.0102999566) < 1e-8)
    }
    @Test func differentArrivalOrdersHaveTheSamePictureAndGapsResetRelease() {
        let a = SpectrogramLaneAccumulator(), b = SpectrogramLaneAccumulator()
        let loud = [Double](repeating:1e-2,count:32), quiet = [Double](repeating:0,count:32)
        a.append(slot:3,trackIndex:0,powers:loud); a.append(slot:4,trackIndex:0,powers:quiet)
        b.append(slot:4,trackIndex:0,powers:quiet); b.append(slot:3,trackIndex:0,powers:loud)
        for lane in [a,b] { lane.append(slot:6,trackIndex:0,powers:quiet) }
        var x: [SpectrogramColumn] = [], y: [SpectrogramColumn] = []
        a.release(through:6) { x.append($0) }; b.release(through:6) { y.append($0) }
        #expect(x == y && x.map(\.slot) == [3,4,6])
        #expect(x[1].bands.allSatisfy { $0 > 0 })
        #expect(x[2].bands.allSatisfy { $0 == 0 })
        a.append(slot:4,trackIndex:2,powers:loud)
        #expect(a.late == 1 && a.pendingCount == 0)
    }
    @Test func aLongStallIsBoundedAndCannotBackpressureTheRecorder() {
        let lane = SpectrogramLaneAccumulator(), silence = [Double](repeating:0,count:32)
        for slot in 0..<10000 { lane.append(slot:Int64(slot),trackIndex:0,powers:silence) }
        #expect(lane.pendingCount == 128 && lane.overflow == 9872)
        var slots: [Int64] = []
        lane.release(through:1_000_000) { slots.append($0.slot) }
        #expect(slots == Array(9872..<10000).map(Int64.init))
        lane.reset(); #expect(lane.pendingCount == 0 && lane.releasedThrough == -1)
    }
    @Test func mailboxHasIndependentLaneLimitsAndKeepsOnlyRecentData() {
        let box = SpectrogramMailbox(), silence = [UInt8](repeating:0,count:32)
        for slot in 0..<100 { box.append(.init(slot:Int64(slot),bands:silence),lane:.others) }
        box.append(.init(slot:9,bands:silence),lane:.me)
        let batch = box.drain()
        #expect(batch.me.map(\.slot) == [9] && batch.others.map(\.slot) == Array(36..<100).map(Int64.init))
        #expect(batch.droppedOthers == 36 && batch.droppedMe == 0)
        #expect(box.drain().others.isEmpty)
        box.reset(); #expect(box.drain().droppedOthers == 0)
    }
    @Test func producerAndDisplayCanDrainConcurrentlyWithoutLosingOrder() async {
        let box = SpectrogramMailbox(), silence = [UInt8](repeating:0,count:32)
        async let producer: Void = Task.detached {
            for slot in 0..<10000 { box.append(.init(slot:Int64(slot),bands:silence),lane:.me) }
        }.value
        var observed: [Int64] = []
        for _ in 0..<1000 { observed += box.drain().me.map(\.slot); await Task.yield() }
        await producer; let final = box.drain(); observed += final.me.map(\.slot)
        #expect(zip(observed,observed.dropFirst()).allSatisfy { $0 < $1 })
        #expect(UInt64(observed.count)+final.droppedMe == 10000)
        #expect(observed.last == 9999)
    }
}
