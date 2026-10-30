// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import Foundation
import Testing
@testable import CassiniRecording

private final class PCMProbe: RecordedPCMObserver, @unchecked Sendable {
    struct Value { let source: RecordedPCMSource, pcm: Data, offset: Double }
    private let lock = NSLock()
    private var values: [Value] = []
    func offer(source: RecordedPCMSource, pcm: Data, offsetMs: Double) {
        lock.withLock { values.append(.init(source:source,pcm:pcm,offset:offsetMs)) }
    }
    var snapshot: [Value] { lock.withLock { values } }
}
private final class PCMStalledWriter: RecordingSinkWriter, @unchecked Sendable {
    let observers = RecordedPCMObservers()
    let recordedPCM: RecordedPCMPolicy?
    let entered = DispatchSemaphore(value:0), unblock = DispatchSemaphore(value:0)
    private let lock = NSLock()
    private var stall = false
    var recordingProblem: String? { nil }
    init() { recordedPCM = RecordedPCMPolicy(observers:observers) }
    func stallNextWrite() { lock.withLock { stall = true } }
    func addTrack(id: String, label: String, kind: String, sampleRate: Int, channels: Int) throws {}
    func appendNative(id: String, pcm: Data, offsetMs: Double) throws {
        if lock.withLock({ let result = stall; stall = false; return result }) { entered.signal(); unblock.wait() }
        recordedPCM?.publish(.init(id:"stored-span",kind:"microphone",sampleRate:8000,channels:1,startOffsetMs:0),for:id)
    }
    func finish(problem: String?) throws {}
}
@Suite struct RecordedPCMTests {
    @Test func readinessHasNoObserverAndActivationUsesTheActualSpanClock() {
        let observers = RecordedPCMObservers(), probe = PCMProbe()
        observers.set(probe)
        let active = RecordedPCMPolicy(observers:observers), staged = RecordedPCMPolicy()
        let source = RecordedPCMSource(id:"actual-span",kind:"system",sampleRate:48000,channels:2,startOffsetMs:125)
        active.publish(source,for:"output")
        let data = Data([1,2,3,4])
        staged.offer(inputID:"output",pcm:data,offsetMs:0)
        #expect(probe.snapshot.isEmpty)
        staged.forward(to:active)
        staged.offer(inputID:"output",pcm:data,offsetMs:130)
        #expect(probe.snapshot.count == 1)
        #expect(probe.snapshot.first?.source == source && probe.snapshot.first?.pcm == data && probe.snapshot.first?.offset == 130)
        observers.set(nil)
        staged.offer(inputID:"output",pcm:data,offsetMs:135)
        #expect(probe.snapshot.count == 1)
    }
    @Test func sessionPublishesOnlyAWrittenSourceWithItsOriginalOffset() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let session = try RecordingSession(parent:root,title:"PCM policy",source:"macos"), probe = PCMProbe()
        session.pcmObservers.set(probe)
        try session.addTrack(id:"mic",label:"Mic",kind:"microphone",sampleRate:8000,channels:1)
        let data = Data([1,2])
        session.recordedPCM?.offer(inputID:"mic",pcm:data,offsetMs:120)
        #expect(probe.snapshot.isEmpty)
        try session.appendNative(id:"mic",pcm:data,offsetMs:120)
        session.recordedPCM?.offer(inputID:"mic",pcm:data,offsetMs:120.125)
        #expect(probe.snapshot.first?.source.startOffsetMs == 120)
        #expect(probe.snapshot.first?.source.id == "mic")
        #expect(probe.snapshot.map(\.offset) == [120,120.125])
        #expect(probe.snapshot.map(\.pcm) == [data,data])
        try session.finish()
    }
    @Test func admittedPictureContinuesDuringAWriterStallAndBudgetLossIsAHole() throws {
        let writer = PCMStalledWriter(), probe = PCMProbe(); writer.observers.set(probe)
        let sink = RecordingSink(session:writer,capacitySeconds:0.15,originHostTime:1) { Issue.record("\($0)") }
        let format = try #require(AVAudioFormat(commonFormat:.pcmFormatFloat32,sampleRate:8000,channels:1,interleaved:false))
        let input = try #require(AVAudioPCMBuffer(pcmFormat:format,frameCapacity:800)); input.frameLength = 800
        for index in 0..<800 { input.floatChannelData![0][index] = index.isMultiple(of:2) ? 0.25 : -0.25 }
        func receive(_ ms: Double) {
            sink.receive(input,hostTime:1+AVAudioTime.hostTime(forSeconds:ms/1000),id:"mic",label:"Mic",kind:"microphone")
        }
        receive(0); sink.flush()
        let baseline = probe.snapshot.count
        writer.stallNextWrite(); receive(100)
        let blocked = writer.entered.wait(timeout:.now()+2)
        defer { writer.unblock.signal(); try? sink.finish(problem:nil) }
        #expect(blocked == .success)
        // 800 frames are pending; another 800 exceed the 1200-frame budget.
        receive(200)
        #expect(probe.snapshot.count == baseline+1,"Admitted PCM is offered without waiting for the disk; dropped PCM is not")
        #expect(abs(try #require(probe.snapshot.last).offset-100) < 0.001)
        writer.unblock.signal(); sink.flush()
        receive(300); sink.flush()
        #expect(abs(try #require(probe.snapshot.last).offset-300) < 0.001,"The next admitted buffer retains the missing timeline interval")
        #expect(probe.snapshot.last?.source.id == "stored-span")
        #expect(probe.snapshot.last?.pcm.count == 1600)
    }
    @Test func bootstrapIsBoundedAndDisappearsImmediatelyWithTheLastView() {
        let observers = RecordedPCMObservers(), probe = PCMProbe()
        observers.set(probe)
        let policy = RecordedPCMPolicy(observers:observers)
        let packet = Data(repeating:1,count:16384)
        for n in 0..<80 { policy.offer(inputID:"mic",pcm:packet,offsetMs:Double(n)*100) }
        #expect(policy.bufferedBytes == 1_048_576)
        #expect(policy.bootstrapDrops == 16)
        #expect(probe.snapshot.isEmpty)
        observers.set(nil)
        #expect(policy.bufferedBytes == 0)
        policy.offer(inputID:"mic",pcm:packet,offsetMs:8000)
        #expect(policy.bufferedBytes == 0)
        observers.set(probe)
        policy.publish(.init(id:"actual",kind:"microphone",sampleRate:48000,channels:1,startOffsetMs:0),for:"mic")
        #expect(probe.snapshot.isEmpty,"Reopening must not replay hidden history")
    }
    @Test func bootstrapLimitsTinyPacketsAndUnknownInputCountAsWellAsBytes() {
        let observers = RecordedPCMObservers(), probe = PCMProbe()
        observers.set(probe)
        let policy = RecordedPCMPolicy(observers:observers)
        for n in 0..<65 { policy.offer(inputID:"first",pcm:Data([1,2]),offsetMs:Double(n)) }
        #expect(policy.bufferedBytes == 128 && policy.bootstrapDrops == 1)
        for n in 0..<64 { policy.offer(inputID:"extra-\(n)",pcm:Data([1,2]),offsetMs:0) }
        #expect(policy.bufferedBytes == 254 && policy.bootstrapDrops == 2)
    }
    @Test func selectionClipsThePrivateBootstrapAtTheActualSampleEvenAfterHours() {
        let observers = RecordedPCMObservers(), probe = PCMProbe()
        observers.set(probe)
        let staged = RecordedPCMPolicy(observers:observers), active = RecordedPCMPolicy(observers:observers)
        let offset = 12*60*60*1000.0+0.125
        let pcm = (0..<24).map { Int16($0).littleEndian }.withUnsafeBytes { Data($0) }
        staged.offer(inputID:"system",pcm:pcm,offsetMs:offset)
        #expect(probe.snapshot.isEmpty)
        staged.forward(to:active)
        #expect(staged.bufferedBytes == 0 && active.bufferedBytes == pcm.count)
        // Three stereo frames: cancellation error in a long floating-point clock
        // must not trim a fourth frame or retain pre-selection readiness audio.
        active.publish(.init(id:"stored",kind:"system",sampleRate:48000,channels:2,
                             startOffsetMs:offset+3.0/48),for:"system")
        #expect(probe.snapshot.count == 1)
        #expect(probe.snapshot.first?.pcm == Data(pcm.dropFirst(12)))
        #expect(probe.snapshot.first?.offset == offset+3.0/48)
        #expect(active.bufferedBytes == 0)
        staged.cancel()
        staged.offer(inputID:"system",pcm:pcm,offsetMs:offset+100)
        #expect(probe.snapshot.count == 1 && staged.bufferedBytes == 0)
    }
    @Test func concurrentActivationCannotStrandAnOfferInTheOldStage() {
        let observers = RecordedPCMObservers(), probe = PCMProbe()
        observers.set(probe)
        let staged = RecordedPCMPolicy(observers:observers), active = RecordedPCMPolicy(observers:observers)
        // Force both possible orderings many times without timers or device I/O.
        let group = DispatchGroup(), producer = DispatchQueue(label:"pcm-test-producer")
        for n in 0..<32 {
            group.enter(); producer.async {
                staged.offer(inputID:"system",pcm:Data([1,2]),offsetMs:Double(n)); group.leave()
            }
            if n == 15 { staged.forward(to:active) }
        }
        group.wait()
        #expect(staged.bufferedBytes == 0 && active.bufferedBytes == 64)
        active.publish(.init(id:"stored",kind:"system",sampleRate:48000,channels:1,startOffsetMs:0),for:"system")
        #expect(probe.snapshot.count == 32)
        #expect(probe.snapshot.map(\.offset) == (0..<32).map(Double.init))
    }
    @Test func closingAViewCannotBePreventedByItsObserverSlot() {
        let observers = RecordedPCMObservers()
        var probe: PCMProbe? = PCMProbe(); weak var weakProbe = probe
        observers.set(probe); probe = nil
        #expect(weakProbe == nil)
    }
}
