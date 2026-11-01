// SPDX-License-Identifier: GPL-3.0-or-later
import Testing
import Foundation
@testable import CassiniSpectrogram

@Suite struct TrackTests {
    @Test func chunkBoundariesKeepTheOriginalFrameGridAndOffset() throws {
        let p = try SpectrogramParameters(), transform = SpectrogramTransform(parameters:try SpectrogramParameters())
        let track = SpectrogramTrack(parameters:p,startOffsetMs:125,transform:transform)
        let source = (0..<9600).map { Float(0.03*sin(2*Double.pi*1000*Double($0)/48000)) }
        var frames: [SpectrogramPowerFrame] = [], offset = 0, chunk = 0
        let chunks = [137,4096,81,8192]
        while offset < source.count {
            let end = min(source.count,offset+chunks[chunk%chunks.count])
            track.append(Array(source[offset..<end]),atFrame:Int64(offset)) { frames.append($0) }
            offset = end; chunk += 1
        }
        #expect(frames.map(\.sampleEnd) == [2880,3840,4800,5760,6720,7680,8640,9600])
        #expect(frames.first?.slot == 8)
        for frame in frames {
            let end = Int(frame.sampleEnd)
            let expected = transform.powers(frame:Array(source[end-p.size..<end]))
            #expect(SpectrogramRelease.raw(powers:frame.powers) == SpectrogramRelease.raw(powers:expected))
            #expect(abs(frame.centreMs - (125 + Double(end-p.size/2)/48)) < 1e-8)
        }
    }
    @Test func noAnalysisFrameMayCrossAMissingInterval() throws {
        let p = try SpectrogramParameters(), transform = SpectrogramTransform(parameters:try SpectrogramParameters())
        let track = SpectrogramTrack(parameters:p,startOffsetMs:0,transform:transform)
        var ends: [Int64] = []
        track.append([Float](repeating:0.1,count:4800),atFrame:0) { ends.append($0.sampleEnd) }
        track.append([Float](repeating:0.1,count:4800),atFrame:7200) { ends.append($0.sampleEnd) }
        #expect(ends.filter{$0 > 4800}.first == 9600)
        #expect(ends.allSatisfy { $0 <= 4800 || $0-Int64(p.size) >= 7200 })
        #expect(track.positionFrames == 12000)
        #expect(track.latestLevel == 0,"A constant DC input has no AC activity")
    }
    @Test func anUnselectedTrackKeepsHistoryWithoutRunningTheFFT() throws {
        let p = try SpectrogramParameters(), transform = SpectrogramTransform(parameters:try SpectrogramParameters())
        let track = SpectrogramTrack(parameters:p,startOffsetMs:0,transform:transform)
        track.append([Float](repeating:0,count:9600),atFrame:0,analyze:false) { _ in Issue.record("Unselected track emitted a frame") }
        #expect(track.analyzedFrames == 0)
        var ends: [Int64] = []
        track.append([Float](repeating:0,count:960),atFrame:9600) { ends.append($0.sampleEnd) }
        #expect(ends == [10560] && track.analyzedFrames == 1)
    }
    @Test func repeatedOverlappingInputDoesNotDuplicateTheTimeline() throws {
        let p = try SpectrogramParameters(), transform = SpectrogramTransform(parameters:try SpectrogramParameters())
        let track = SpectrogramTrack(parameters:p,startOffsetMs:0,transform:transform)
        var ends: [Int64] = []
        track.append([Float](repeating:0,count:4800),atFrame:0) { ends.append($0.sampleEnd) }
        track.append([Float](repeating:0,count:5000),atFrame:4600) { ends.append($0.sampleEnd) }
        #expect(ends.count == 8 && Set(ends).count == 8)
        #expect(track.positionFrames == 9600)
    }
}
