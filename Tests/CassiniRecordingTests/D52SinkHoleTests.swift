// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import Foundation
import Testing
@testable import CassiniRecording

/// Forwards everything to a real session; the first audio write blocks until released,
/// so the sink drops what arrives meanwhile. No sleeps: the test waits on `entered`.
private final class GatedSession: RecordingSinkWriter, @unchecked Sendable {
    let session: RecordingSession
    let entered = DispatchSemaphore(value:0), release = DispatchSemaphore(value:0)
    private var gate = true
    init(_ session: RecordingSession) { self.session = session }
    var recordingProblem: String? { session.recordingProblem }
    func addTrack(id: String, label: String, kind: String, sampleRate: Int, channels: Int) throws { try session.addTrack(id:id,label:label,kind:kind,sampleRate:sampleRate,channels:channels) }
    func appendNative(id: String, pcm: Data, offsetMs: Double) throws { try appendNative(id:id,pcm:pcm,offsetMs:offsetMs,gapKind:"input") }
    func appendNative(id: String, pcm: Data, offsetMs: Double, gapKind: String) throws {
        if gate { gate = false; entered.signal(); release.wait() }
        try session.appendNative(id:id,pcm:pcm,offsetMs:offsetMs,gapKind:gapKind)
    }
    func padNative(id: String, frames: UInt64, channels: Int, rate: Double, offsetMs: Double, kind: String) throws {
        try session.padNative(id:id,frames:frames,channels:channels,rate:rate,offsetMs:offsetMs,kind:kind)
    }
    func finish(problem: String?) throws { try session.finish(problem:problem) }
    func finish(problem: String?, kind: String?) throws { try session.finish(problem:problem,kind:kind) }
    func reportLoss(id: String, droppedFrames: UInt64, gapFrames: UInt64) { session.reportLoss(id:id,droppedFrames:droppedFrames,gapFrames:gapFrames) }
}

/// codex #106: drops and host-time gaps are separate holes, each padded with its own kind.
@Suite struct D52SinkHoleTests {
    private func buffer() throws -> AVAudioPCMBuffer {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate:8000,channels:1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat:format,frameCapacity:80))
        buffer.frameLength = 80
        for i in 0..<80 { buffer.floatChannelData![0][i] = 0.25 }
        return buffer
    }
    private func host(_ seconds: Double) -> UInt64 { 1 + AVAudioTime.hostTime(forSeconds:seconds) }
    private func setUp() throws -> (URL,RecordingSession,GatedSession,RecordingSink) {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("D52Holes-"+UUID().uuidString)
        let session = try RecordingSession(parent:parent,title:"Holes",source:"macos")
        let writer = GatedSession(session)
        // 10 ms of capacity at 8 kHz: one 80-frame buffer may be pending at a time.
        return (parent,session,writer,RecordingSink(session:writer,capacitySeconds:0.01,originHostTime:1) { _ in })
    }

    @Test func aDropThenAHostGapThenADropArePaddedInOrderWithTheirKinds() throws {
        let (parent,session,writer,sink) = try setUp(); defer { try? FileManager.default.removeItem(at:parent) }
        let audio = try buffer()
        sink.receive(audio,hostTime:host(0),id:"mic",label:"Mic",kind:"microphone")
        #expect(writer.entered.wait(timeout:.now() + 5) == .success,"The first write is blocked")
        sink.receive(audio,hostTime:host(0.01),id:"mic",label:"Mic",kind:"microphone")   // dropped: writer
        sink.receive(audio,hostTime:host(2.02),id:"mic",label:"Mic",kind:"microphone")   // 2 s host gap (input), then dropped (writer)
        writer.release.signal(); sink.flush()
        sink.receive(audio,hostTime:host(2.03),id:"mic",label:"Mic",kind:"microphone")   // admitted: pads all three holes
        sink.flush()
        let track = try #require(session.manifest.tracks.first)
        #expect(track.gaps?.map(\.kind) == ["writer","input","writer"])
        #expect(track.gaps?.map(\.frames) == [80,16000,80])
        #expect(track.gapFrames == 16000,"Only the host-time gap counts as gapFrames")
        #expect(track.frames == 80 + 80 + 16000 + 80 + 80)
        // D69.2: the file still ends as io with D69's sentence. Stop reports the real 2 s gap as a
        // gap alone would, never the stored writer sentence.
        do { try sink.finish(problem:nil); Issue.record("the gap must still be reported at Stop") }
        catch { #expect(error.localizedDescription == "Recording saved with 2000 ms of host-time gap; the timeline contains silence.") }
        #expect(session.manifest.tracks[0].droppedFrames == 160 && session.manifest.problemKind == "io")
        #expect(session.manifest.problem?.hasSuffix("audio was lost because the computer could not keep up; the gaps contain silence.") == true)
    }

    @Test func pauseClearsPaddedDropsSoALaterHostGapIsInput() throws {
        let (parent,session,writer,sink) = try setUp(); defer { try? FileManager.default.removeItem(at:parent) }
        let audio = try buffer()
        sink.receive(audio,hostTime:host(0),id:"mic",label:"Mic",kind:"microphone")
        #expect(writer.entered.wait(timeout:.now() + 5) == .success,"The first write is blocked")
        sink.receive(audio,hostTime:host(0.01),id:"mic",label:"Mic",kind:"microphone")   // dropped: writer
        writer.release.signal()
        try sink.pause()                                                                 // pads the dropped tail
        #expect(session.manifest.tracks[0].gaps?.map(\.kind) == ["writer"])
        try sink.resume()
        sink.receive(audio,hostTime:host(2.02),id:"mic",label:"Mic",kind:"microphone")   // 2 s host gap, admitted
        sink.flush()
        let track = try #require(session.manifest.tracks.first)
        #expect(track.gaps?.map(\.kind) == ["writer","input"],"The padded drop is not labelled again")
        #expect(track.gaps?.map(\.frames) == [80,16000] && track.gapFrames == 16000)
        #expect(track.frames == 80 + 80 + 16000 + 80)
    }
}
