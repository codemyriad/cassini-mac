// SPDX-License-Identifier: GPL-3.0-or-later
import Testing
import Foundation
import CassiniRecording
import os
@testable import CassiniSpectrogram

private final class SpectrumTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 200.0
    func set(_ value: Double) { lock.withLock { self.value = value } }
    func read() -> Double { lock.withLock { value } }
}
private final class RetainedPCM: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = 0, calls = 0, first = true
    var count: Int { lock.withLock { bytes } }
    var clockCalls: Int { lock.withLock { calls } }
    func takeFirst() -> Bool { lock.withLock { calls += 1; let result = first; first = false; return result } }
    func packet() -> Data {
        let size = 96000
        let base = UnsafeMutableRawPointer.allocate(byteCount:size,alignment:2)
        base.initializeMemory(as:UInt8.self,repeating:0,count:size)
        lock.withLock { bytes += size }
        return Data(bytesNoCopy:base,count:size,deallocator:.custom { [self] pointer,count in
            pointer.deallocate(); lock.withLock { bytes -= count }
        })
    }
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
    @Test func displayDrainDoesNotWaitForTheAnalysisQueueAndRejectsItsOldGeneration() async throws {
        let entered = DispatchSemaphore(value:0), proceed = DispatchSemaphore(value:0), completed = DispatchSemaphore(value:0)
        let session = SpectrogramSession(clock:{ entered.signal(); proceed.wait(); return 200 })
        session.setVisible(true)
        let source = RecordedPCMSource(id:"mic",kind:"microphone",sampleRate:48000,channels:1,startOffsetMs:0)
        session.offer(source:source,pcm:tone(),offsetMs:0)
        defer { proceed.signal() }
        let blocked = await withCheckedContinuation { c in
            DispatchQueue.global().async { c.resume(returning:entered.wait(timeout:.now()+2)) }
        }
        try #require(blocked == .success)
        let result = OSAllocatedUnfairLock<SpectrogramSession.Frame?>(initialState:nil)
        DispatchQueue.global().async {
            let picture = session.pollFrame(nowMs:0)
            result.withLock { $0 = picture }; completed.signal()
        }
        let drained = await withCheckedContinuation { c in
            DispatchQueue.global().async { c.resume(returning:completed.wait(timeout:.now()+2)) }
        }
        try #require(drained == .success,"A display must not wait for queued/active analysis work")
        #expect(result.withLock { $0?.me.isEmpty == true && $0?.retainedTracks == 0 })
        session.setVisible(false);session.setVisible(true)
        #expect(session.pollFrame(nowMs:0).analyzedFrames == 0)
        proceed.signal()
        let obsolete = await frame(session,at:200)
        #expect(obsolete.me.isEmpty && obsolete.retainedTracks == 0 && obsolete.analyzedFrames == 0)
    }
    @Test func synchronousDrainKeepsTheStoppedAudioClock() async {
        let session = SpectrogramSession(clock:{ 200 })
        session.setVisible(true)
        let source = RecordedPCMSource(id:"mic",kind:"microphone",sampleRate:48000,channels:1,startOffsetMs:0)
        session.offer(source:source,pcm:tone(),offsetMs:0)
        _ = await frame(session,at:0)
        session.stop(atMs:100)
        let stopped = session.pollFrame(nowMs:500), later = session.pollFrame(nowMs:5000)
        #expect(stopped.displayMs == later.displayMs && later.displayMs <= 100)
        let count = later.analyzedFrames
        session.offer(source:source,pcm:tone(),offsetMs:4096.0/48)
        #expect(await frame(session,at:5000).analyzedFrames == count)
    }
    @Test(arguments:[false,true]) func lateTimingIsBoundedAndOnlyCollectedForMeasurement(_ measured: Bool) async {
        let session = SpectrogramSession(clock:{ 10000 },measureCPU:measured)
        session.setVisible(true)
        _ = await frame(session,at:10000)
        let source = RecordedPCMSource(id:"mic",kind:"microphone",sampleRate:48000,channels:1,startOffsetMs:0)
        let pcm = Data(repeating:0,count:4096*2)
        for n in 0..<8 { session.offer(source:source,pcm:pcm,offsetMs:Double(n*4096)/48) }
        let late = await frame(session,at:10000)
        #expect(late.lateColumns > 16)
        #expect(late.lateSamples.count == (measured ? 16 : 0))
        if measured {
            #expect(late.lateSamples.last?.ordinal == late.lateColumns)
            #expect(late.lateSamples.allSatisfy { $0.slot <= $0.releasedThrough && $0.arrivalMs == 10000 })
        }
        session.setVisible(false);session.setVisible(true)
        #expect(await frame(session,at:10000).lateSamples.isEmpty)
    }
    @Test(arguments:[4096,8192]) func continuousDisplayDoesNotReleaseChunkColumnsBeforeTheirSlotsArrive(_ chunk: Int) async {
        let time = SpectrumTestClock(); time.set(0)
        let session = SpectrogramSession(clock:{ time.read() }); session.setVisible(true)
        let source = RecordedPCMSource(id:"mic",kind:"microphone",sampleRate:48000,channels:1,startOffsetMs:0)
        let pcm = Data(repeating:0,count:chunk*2)
        var packet = 0, steadyLate: UInt64 = 0, last: SpectrogramSession.Frame?
        for tick in 0...1800 {
            let now = Double(tick)*1000/60
            while 120+Double((packet+1)*chunk)/48 <= now {
                time.set(120+Double((packet+1)*chunk)/48)
                session.offer(source:source,pcm:pcm,offsetMs:Double(packet*chunk)/48)
                _ = await frame(session,at:now)
                packet += 1
            }
            time.set(now)
            let picture = await frame(session,at:now)
            if tick == 300 { steadyLate = picture.lateColumns }
            last = picture
        }
        #expect(last?.lateColumns == steadyLate,"A continuous60Hz display must not discard steady4096/8192-frame packets")
        #expect(last?.droppedBuffers == 0 && last?.droppedColumns == 0)
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
    @Test(arguments:["microphone","local"]) func nativeAndBrowserMicrophonesRemainInTheMeLane(_ kind:String) async {
        let session=SpectrogramSession(clock:{200});session.setVisible(true)
        let source=RecordedPCMSource(id:"microphone-source",kind:kind,sampleRate:48000,channels:1,startOffsetMs:0)
        session.offer(source:source,pcm:tone(),offsetMs:0)
        let result=await frame(session,at:200)
        #expect(result.me.contains { $0.bands.contains { $0>0 } })
        #expect(result.others.isEmpty,"A browser local source must not be drawn as another speaker")
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
    @Test func tinyPacketsCannotAccumulateUnboundedDispatchWork() async throws {
        let memory = RetainedPCM(), entered = DispatchSemaphore(value:0), proceed = DispatchSemaphore(value:0)
        let session = SpectrogramSession(clock:{
            if memory.takeFirst() { entered.signal(); proceed.wait() }
            return 2000
        })
        session.setVisible(true)
        let held = RecordedPCMSource(id:"held",kind:"microphone",sampleRate:48000,channels:1,startOffsetMs:0)
        session.offer(source:held,pcm:memory.packet(),offsetMs:0)
        defer { proceed.signal() }
        let blocked = await withCheckedContinuation { c in
            DispatchQueue.global().async { c.resume(returning:entered.wait(timeout:.now()+2)) }
        }
        try #require(blocked == .success)
        let tiny = RecordedPCMSource(id:"tiny",kind:"remote",sampleRate:48000,channels:1,startOffsetMs:0)
        for n in 0..<96 { session.offer(source:tiny,pcm:Data([0,0]),offsetMs:Double(n)/48) }
        proceed.signal()
        let result = await frame(session,at:2000)
        #expect(memory.clockCalls == 65,"At most64 pending packets per source, plus the independent held source")
        #expect(result.droppedBuffers == 32)
    }
    @Test func repeatedHideShowCannotResetTheBudgetOfStillRetainedPackets() async throws {
        let memory = RetainedPCM(), entered = DispatchSemaphore(value:0), proceed = DispatchSemaphore(value:0)
        let session = SpectrogramSession(clock:{
            if memory.takeFirst() { entered.signal(); proceed.wait() }
            return 20000
        })
        session.setVisible(true)
        let source = RecordedPCMSource(id:"mic",kind:"microphone",sampleRate:48000,channels:1,startOffsetMs:0)
        session.offer(source:source,pcm:memory.packet(),offsetMs:0)
        defer { proceed.signal() }
        let blocked = await withCheckedContinuation { c in
            DispatchQueue.global().async { c.resume(returning:entered.wait(timeout:.now()+2)) }
        }
        try #require(blocked == .success)
        #expect(memory.count == 96000)
        for n in 1...8 {
            session.setVisible(false); session.setVisible(true)
            session.offer(source:source,pcm:memory.packet(),offsetMs:Double(n)*1000)
        }
        // Observe actual Data ownership, not the admission counter: clearing a
        // counter cannot release old dispatch closures that retain their PCM.
        #expect(memory.count <= 96000,"All view generations share the same bounded input budget")
        proceed.signal()
        let result = await frame(session,at:20000)
        #expect(result.retainedTracks == 0 && result.analyzedFrames == 0,"Obsolete in-flight work cannot repopulate the reopened view")
        #expect(result.droppedBuffers == 1,"The latest view counts its rejected packet until the old reservation drains")
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
        #expect(ended.analyzedFrames == 8 && ended.retainedTracks == 3)
    }
    @Test func manyReplacementsReuseEndedSlotsWithoutLosingLiveAnalysis() async {
        let time = SpectrumTestClock(), session = SpectrogramSession(clock:{ time.read() })
        session.setVisible(true)
        let data = tone()
        for index in 0..<80 {
            let start = Double(index)*200
            time.set(start+120)
            let source = RecordedPCMSource(id:"replacement-\(index)",kind:"remote",sampleRate:48000,channels:1,startOffsetMs:start)
            session.offer(source:source,pcm:data,offsetMs:start)
            let live = await frame(session,at:start+200)
            #expect(live.retainedTracks == 1,"Ended source histories must not accumulate")
            #expect(live.analyzedFrames == UInt64((index+1)*2),"The 65th and later source still produces real FFT frames")
            #expect(!live.others.isEmpty)
            session.sourceEnded(id:source.id)
            let ended = await frame(session,at:start+201)
            #expect(ended.retainedTracks == 0 && ended.analyzedFrames == live.analyzedFrames)
        }
        session.setVisible(false)
        let hidden = await frame(session,at:16200)
        #expect(hidden.analyzedFrames == 0 && hidden.retainedTracks == 0)
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
