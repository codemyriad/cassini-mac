// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import Foundation
import XCTest
import CassiniRecording
@testable import CassiniBrowserControl

private final class D69GatedWriter: RecordingSinkWriter, @unchecked Sendable {
    let target: any RecordingSinkWriter
    let entered = DispatchSemaphore(value:0), release = DispatchSemaphore(value:0)
    private var gate = true
    init(_ target: any RecordingSinkWriter) { self.target = target }
    var recordingProblem: String? { target.recordingProblem }
    func addTrack(id:String,label:String,kind:String,sampleRate:Int,channels:Int) throws { try target.addTrack(id:id,label:label,kind:kind,sampleRate:sampleRate,channels:channels) }
    func appendNative(id:String,pcm:Data,offsetMs:Double) throws { try appendNative(id:id,pcm:pcm,offsetMs:offsetMs,gapKind:"input") }
    func appendNative(id:String,pcm:Data,offsetMs:Double,gapKind:String) throws {
        if gate { gate = false; entered.signal(); release.wait() }
        try target.appendNative(id:id,pcm:pcm,offsetMs:offsetMs,gapKind:gapKind)
    }
    func padNative(id:String,frames:UInt64,channels:Int,rate:Double,offsetMs:Double,kind:String) throws { try target.padNative(id:id,frames:frames,channels:channels,rate:rate,offsetMs:offsetMs,kind:kind) }
    func reportLoss(id:String,droppedFrames:UInt64,gapFrames:UInt64) { target.reportLoss(id:id,droppedFrames:droppedFrames,gapFrames:gapFrames) }
    func finish(problem:String?) throws { try target.finish(problem:problem) }
    func finish(problem:String?,kind:String?) throws { try target.finish(problem:problem,kind:kind) }
}

final class D69WriterLossTests: XCTestCase {
    private func buffer() throws -> AVAudioPCMBuffer {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate:8000,channels:1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat:format,frameCapacity:80)); buffer.frameLength = 80
        for index in 0..<80 { buffer.floatChannelData![0][index] = 0.25 }
        return buffer
    }
    func testQueueDroppedTailKeepsEverySourceDiagnosticAfterUserStop() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("D69Sources-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let owner = try OwnedBrowserCapture(parent:root,title:"Loss",microphone:true,browser:false)
        let micWriter = D69GatedWriter(owner.nativeWriter(side:.me)), sysWriter = D69GatedWriter(owner.nativeWriter(side:.others))
        let mic = RecordingSink(session:micWriter,capacitySeconds:0.01,originHostTime:1) { _ in }
        let sys = RecordingSink(session:sysWriter,capacitySeconds:0.01,originHostTime:1) { _ in }
        let audio = try buffer()
        mic.receive(audio,hostTime:1,id:"mic",label:"Mic",kind:"microphone")
        XCTAssertEqual(micWriter.entered.wait(timeout:.now()+5),.success)
        defer { micWriter.release.signal(); sysWriter.release.signal() }
        mic.receive(audio,hostTime:1+AVAudioTime.hostTime(forSeconds:0.009),id:"mic",label:"Mic",kind:"microphone")
        sys.receive(audio,hostTime:1,id:"sys",label:"System",kind:"system")
        XCTAssertEqual(sysWriter.entered.wait(timeout:.now()+5),.success)
        for seconds in [0.01,0.02] { sys.receive(audio,hostTime:1+AVAudioTime.hostTime(forSeconds:seconds),id:"sys",label:"System",kind:"system") }
        XCTAssertTrue(owner.requestEnd(.user,atMs:19))
        micWriter.release.signal(); mic.flush()
        sysWriter.release.signal(); sys.flush()
        try mic.finish(problem:"Microphone diagnostic.")
        try sys.finish(problem:"System diagnostic.")
        try await owner.finish(problem:"Earlier capture warning.",reason:.user,atMs:19)
        let manifest = try RecordingLoader.load(directory:owner.snapshot.directory)
        XCTAssertEqual(manifest.state,"interrupted"); XCTAssertEqual(manifest.problemKind,"io")
        XCTAssertEqual(manifest.events?.last?.reason,"error"); XCTAssertEqual(manifest.events?.filter { $0.type == "end" }.count,1)
        XCTAssertEqual(manifest.problem,"Earlier capture warning. Microphone diagnostic. System diagnostic. 10 ms of microphone audio was lost because the computer could not keep up; the gaps contain silence. 20 ms of system audio was lost because the computer could not keep up; the gaps contain silence.")
        XCTAssertEqual(manifest.tracks.map(\.droppedFrames),[80,160])
        XCTAssertEqual(manifest.tracks.map(\.receivedFrames),[80,80])
        XCTAssertEqual(manifest.tracks.map { $0.gapFrames ?? 0 },[0,0])
        for track in manifest.tracks {
            let wav = try Data(contentsOf:owner.snapshot.directory.appendingPathComponent(track.file))
            XCTAssertTrue(wav[204...].allSatisfy { $0 == 0 })
        }
        let before = try Data(contentsOf:owner.snapshot.directory.appendingPathComponent("session.json"))
        try await owner.finish(reason:.error,atMs:100)
        XCTAssertEqual(try Data(contentsOf:owner.snapshot.directory.appendingPathComponent("session.json")),before)
    }
    func testLossCopyUsesPaddingTotalsAfterRangeOverflowAndIgnoresProducerDrops() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("D69Budget-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let session = try RecordingSession(parent:root,title:"Loss",source:"macos")
        try session.addTrack(id:"mic",label:"Mic",kind:"microphone",sampleRate:8000,channels:1)
        try session.appendNative(id:"mic",pcm:Data(repeating:1,count:16),offsetMs:0)
        for index in 0..<1001 { try session.padNative(id:"mic",frames:4,channels:1,rate:8000,offsetMs:1+Double(index)/2) }
        session.addDroppedFrames(id:"mic",frames:99999)
        try session.finish(problem:"Earlier warning.",kind:nil,reason:.user)
        XCTAssertEqual(session.manifest.tracks[0].gaps?.last?.kind,"overflow")
        XCTAssertEqual(session.manifest.problem,"Earlier warning. 501 ms of microphone audio was lost because the computer could not keep up; the gaps contain silence.")
        XCTAssertEqual(session.manifest.events?.last?.reason,"error")
    }
    func testOneSourceWithDifferentSpanRatesRoundsTheExactCombinedDurationOnce() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("D69Rates-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let session = try RecordingSession(parent:root,title:"Loss",source:"macos")
        // 2/12000 s + 10/30000 s = exactly 0.5 ms. Each range alone rounds to 0.
        try session.transition(starting:[
            .init(id:"a",label:"Application",kind:"application",sampleRate:12000,channels:1,sourceTrackId:"app"),
            .init(id:"b",label:"Application",kind:"application",sampleRate:30000,channels:1,sourceTrackId:"app")])
        for (id,rate,frames) in [("a",12000,2),("b",30000,10)] {
            try session.appendNative(id:id,pcm:Data(repeating:1,count:2),offsetMs:0)
            try session.padNative(id:id,frames:UInt64(frames),channels:1,rate:Double(rate),offsetMs:1000/Double(rate))
        }
        try session.finish(problem:nil)
        XCTAssertEqual(session.manifest.problem,"1 ms of application audio was lost because the computer could not keep up; the gaps contain silence.")
    }
    func testNativeSourceLossAcrossReenabledSpansRoundsOnce() async throws {
        for (side,kind) in [(CaptureSide.me,"microphone"),(CaptureSide.others,"system")] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("D69Spans-"+UUID().uuidString)
            defer { try? FileManager.default.removeItem(at:root) }
            let owner = try OwnedBrowserCapture(parent:root,title:"Reenabled source",microphone:true,browser:false)
            for (index,offset) in [0.0,2.0].enumerated() {
                if index > 0 {
                    try await owner.select(me:side != .me,others:side != .others,atMs:1)
                    try await owner.select(me:true,others:true,atMs:2)
                }
                // Each input generation creates a fresh real native span with no
                // sourceTrackId. Two 0.25 ms losses must produce one 1 ms sentence.
                let writer = owner.nativeWriter(side:side)
                try writer.addTrack(id:"callback",label:kind,kind:kind,sampleRate:8000,channels:1)
                try writer.appendNative(id:"callback",pcm:Data(repeating:1,count:2),offsetMs:offset)
                try writer.padNative(id:"callback",frames:2,channels:1,rate:8000,offsetMs:offset+0.125,kind:"writer")
                try writer.finish(problem:"Span \(index+1) diagnostic.",kind:"io")
            }
            try await owner.finish(problem:"Earlier warning.",reason:.user,atMs:3)
            let manifest = try RecordingLoader.load(directory:owner.snapshot.directory)
            XCTAssertEqual(manifest.tracks.count,2,kind)
            XCTAssertEqual(Set(manifest.tracks.map(\.id)).count,2,kind)
            XCTAssertTrue(manifest.tracks.allSatisfy { $0.kind == kind && $0.sourceTrackId == nil },kind)
            XCTAssertEqual(manifest.tracks.map(\.droppedFrames),[2,2],kind)
            XCTAssertEqual(manifest.problem,"Earlier warning. Span 1 diagnostic. Span 2 diagnostic. 1 ms of \(kind) audio was lost because the computer could not keep up; the gaps contain silence.",kind)
            XCTAssertEqual(manifest.problemKind,"io",kind)
            XCTAssertEqual(manifest.events?.last?.reason,"error",kind)
        }
    }
    func testKnownLossWithoutHostStampsStaysExactAndUnstampedTailIsRejected() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("D69Stamp-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let session = try RecordingSession(parent:root,title:"Loss",source:"macos")
        let origin = AVAudioTime.hostTime(forSeconds:ProcessInfo.processInfo.systemUptime)
        let sink = RecordingSink(session:session,originHostTime:origin) { _ in }
        let audio = try buffer()
        sink.receive(audio,hostTime:0,id:"mic",label:"Mic",kind:"microphone"); sink.flush()
        sink.receive(audio,hostTime:0,id:"mic",label:"Mic",kind:"microphone",writerLoss:.known(frames:80)); sink.flush()
        // Without a trustworthy host-end, no additional loss can be inferred.
        XCTAssertThrowsError(try sink.recordWriterTail(id:"mic",untilHostTime:origin))
        try sink.recordWriterTail(id:"mic",untilHostTime:origin,loss:.known(frames:80))
        XCTAssertThrowsError(try sink.recordWriterTail(id:"mic",untilHostTime:origin,loss:.known(frames:80)))
        XCTAssertThrowsError(try sink.finish(problem:nil))
        XCTAssertEqual(session.manifest.tracks[0].frames,320)
        XCTAssertEqual(session.manifest.tracks[0].droppedFrames,160)
        XCTAssertEqual(session.manifest.problem,"20 ms of microphone audio was lost because the computer could not keep up; the gaps contain silence.")
        XCTAssertThrowsError(try sink.recordWriterTail(id:"mic",untilHostTime:origin))
    }

}
