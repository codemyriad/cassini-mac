// SPDX-License-Identifier: GPL-3.0-or-later
import Testing
import Foundation
import CassiniRecording
@testable import CassiniSpectrogram

private final class SpectrumTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 200.0
    func set(_ value: Double) { lock.withLock { self.value = value } }
    func read() -> Double { lock.withLock { value } }
}
@Suite struct SessionTests {
    private func frame(_ session: SpectrogramSession, at ms: Double) async -> SpectrogramSession.Frame {
        await withCheckedContinuation { continuation in session.requestFrame(nowMs:ms) { continuation.resume(returning:$0) } }
    }
    private func tone(frames: Int = 4096, channels: Int = 1) -> Data {
        var values = [Int16](repeating:0,count:frames*channels)
        for index in 0..<frames { for channel in 0..<channels { values[index*channels+channel] = Int16(1000*sin(2*Double.pi*1000*Double(index)/48000)).littleEndian } }
        return values.withUnsafeBytes { Data($0) }
    }
    @Test func hiddenSessionsDoNoAnalysisAndReopeningCannotReuseOldHistory() async throws {
        let time = SpectrumTestClock(), session = SpectrogramSession(clock:{ time.read() })
        let source = RecordedPCMSource(id:"mic",kind:"microphone",sampleRate:48000,channels:1,startOffsetMs:0)
        let pcm = tone()
        session.offer(source:source,pcm:pcm,offsetMs:0)
        let hidden = await frame(session,at:200)
        #expect(hidden.analyzedFrames == 0 && hidden.retainedTracks == 0 && hidden.me.isEmpty)
        session.setVisible(true); session.offer(source:source,pcm:pcm,offsetMs:0)
        let visible = await frame(session,at:200)
        #expect(visible.analyzedFrames > 0 && visible.me.contains { $0.bands.contains { $0 > 0 } })
        session.setVisible(false); session.offer(source:source,pcm:pcm,offsetMs:Double(4096)/48)
        let closed = await frame(session,at:400)
        #expect(closed.analyzedFrames == 0 && closed.retainedTracks == 0 && closed.me.isEmpty)
        time.set(500); session.setVisible(true)
        session.offer(source:source,pcm:pcm,offsetMs:Double(8192)/48)
        let reopened = await frame(session,at:500)
        #expect(!reopened.me.isEmpty && reopened.me.allSatisfy { $0.slot >= 9 },"Fresh history uses the original source clock and crosses no hidden interval")
    }
    @Test func bothLanesStartWithoutAnEmptyLaneConsumingItsSelectionPeriod() async {
        let session = SpectrogramSession(clock:{ 200 }); session.setVisible(true)
        let me = RecordedPCMSource(id:"mic",kind:"microphone",sampleRate:48000,channels:1,startOffsetMs:0)
        let others = RecordedPCMSource(id:"remote",kind:"remote",sampleRate:48000,channels:2,startOffsetMs:0)
        session.offer(source:me,pcm:tone(),offsetMs:0)
        session.offer(source:others,pcm:tone(channels:2),offsetMs:0)
        let result = await frame(session,at:200)
        #expect(!result.me.isEmpty && !result.others.isEmpty)
        #expect(result.me.map(\.bands) == result.others.map(\.bands),"Stereo averages channels before the same transform")
    }
    @Test func inputBudgetDropsPictureDataWithoutBlockingOrChangingTheSourceClock() async {
        let entered = DispatchSemaphore(value:0), proceed = DispatchSemaphore(value:0)
        let session = SpectrogramSession(clock:{ entered.signal(); proceed.wait(); return 2000 })
        session.setVisible(true)
        let source = RecordedPCMSource(id:"mic",kind:"microphone",sampleRate:48000,channels:1,startOffsetMs:0)
        session.offer(source:source,pcm:tone(frames:48000),offsetMs:0)
        let blocked = await withCheckedContinuation { continuation in
            DispatchQueue.global().async { continuation.resume(returning:entered.wait(timeout:.now()+2)) }
        }
        #expect(blocked == .success)
        session.offer(source:source,pcm:Data([0,0]),offsetMs:1000)
        proceed.signal()
        let result = await frame(session,at:2000)
        #expect(result.droppedBuffers == 1 && result.analyzedFrames > 0)
        session.stop(atMs:2000)
        session.offer(source:source,pcm:Data([0,0]),offsetMs:1000)
        let stopped = await frame(session,at:3000)
        #expect(stopped.analyzedFrames == result.analyzedFrames && stopped.displayMs <= 2000)
    }
    @Test func aCommittedSourceEndReleasesItsAnalysisSlotForTheReplacement() async {
        let time = SpectrumTestClock(), session = SpectrogramSession(clock:{ time.read() }); session.setVisible(true)
        let data = tone()
        for index in 0..<3 {
            session.offer(source:.init(id:"old-\(index)",kind:"remote",sampleRate:48000,channels:1,startOffsetMs:0),pcm:data,offsetMs:0)
        }
        let before = await frame(session,at:200)
        #expect(before.analyzedFrames == 6)
        session.sourceEnded(id:"old-0"); time.set(300)
        session.offer(source:.init(id:"replacement",kind:"remote",sampleRate:48000,channels:1,startOffsetMs:200),pcm:data,offsetMs:200)
        _ = await frame(session,at:300)
        let after = await frame(session,at:400)
        #expect(after.analyzedFrames == 8 && !after.others.isEmpty,"Replacement does not wait a second behind a departed source")
        session.sourceEnded(id:"already-ended")
        session.offer(source:.init(id:"already-ended",kind:"remote",sampleRate:48000,channels:1,startOffsetMs:400),pcm:data,offsetMs:400)
        let ended = await frame(session,at:500)
        #expect(ended.analyzedFrames == 8 && ended.retainedTracks == 4)
    }
    @Test func unalignedPCMIsSafeAndOppositeStereoChannelsCancelBeforeAnalysis() async {
        let data = tone(channels:2)
        let storage = UnsafeMutableRawPointer.allocate(byteCount:data.count+1,alignment:16)
        defer { storage.deallocate() }
        data.copyBytes(to:UnsafeMutableRawBufferPointer(start:storage+1,count:data.count))
        let odd = Data(bytesNoCopy:storage+1,count:data.count,deallocator:.none)
        #expect(odd.withUnsafeBytes { UInt(bitPattern:$0.baseAddress!)%2 == 1 })
        let source = RecordedPCMSource(id:"stereo",kind:"remote",sampleRate:48000,channels:2,startOffsetMs:0)
        let a = SpectrogramSession(clock:{ 200 }); a.setVisible(true); a.offer(source:source,pcm:odd,offsetMs:0)
        let picture = await frame(a,at:200)
        #expect(!picture.others.isEmpty && picture.others.contains { $0.bands.contains { $0 > 0 } })
        var inverse = data
        inverse.withUnsafeMutableBytes { bytes in
            for index in stride(from:2,to:bytes.count,by:4) {
                let sample = Int16(littleEndian:bytes.loadUnaligned(fromByteOffset:index,as:Int16.self))
                bytes.storeBytes(of:(-sample).littleEndian,toByteOffset:index,as:Int16.self)
            }
        }
        let b = SpectrogramSession(clock:{ 200 }); b.setVisible(true); b.offer(source:source,pcm:inverse,offsetMs:0)
        let silence = await frame(b,at:200)
        #expect(!silence.others.isEmpty && silence.others.allSatisfy { $0.bands.allSatisfy { $0 == 0 } })
    }

}
