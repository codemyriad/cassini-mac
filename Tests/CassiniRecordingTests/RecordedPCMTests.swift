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
    @Test func closingAViewCannotBePreventedByItsObserverSlot() {
        let observers = RecordedPCMObservers()
        var probe: PCMProbe? = PCMProbe(); weak var weakProbe = probe
        observers.set(probe); probe = nil
        #expect(weakProbe == nil)
    }
}
