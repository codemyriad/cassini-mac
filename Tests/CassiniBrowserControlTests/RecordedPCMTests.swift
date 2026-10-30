// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
import CassiniRecording
@testable import CassiniBrowserControl

private final class AdmittedPCMProbe: RecordedPCMObserver, @unchecked Sendable {
    struct Sample { let source: RecordedPCMSource, pcm: Data, offset: Double }
    private let lock = NSLock()
    private var samples: [Sample] = []
    func offer(source: RecordedPCMSource, pcm: Data, offsetMs: Double) { lock.withLock { samples.append(.init(source:source,pcm:pcm,offset:offsetMs)) } }
    var snapshot: [Sample] { lock.withLock { samples } }
}
@Suite struct CapturePCMTests {
    private func parent() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        return root
    }
    @Test func stagedNativeAudioPublishesOnlyAfterActivationAndUsesTheTrimmedSpan() async throws {
        let root = try parent(); defer { try? FileManager.default.removeItem(at:root) }
        let capture = try OwnedBrowserCapture(parent:root,title:"Prepared microphone",microphone:false,browser:false)
        let probe = AdmittedPCMProbe(); capture.pcmObservers.set(probe)
        let stage = StagedNativeWriter(), bytes = Data(repeating:0,count:1600)
        try stage.addTrack(id:"mic",label:"Mic",kind:"microphone",sampleRate:8000,channels:1)
        try stage.appendNative(id:"mic",pcm:bytes,offsetMs:0)
        try stage.appendNative(id:"mic",pcm:bytes,offsetMs:100)
        stage.recordedPCM?.offer(inputID:"mic",pcm:bytes,offsetMs:100)
        #expect(probe.snapshot.isEmpty)
        #expect(capture.snapshot.manifest.tracks.isEmpty)
        try await capture.select(me:true,others:true,atMs:150,reservingNative:[.me])
        try stage.activate(capture.nativeWriter(side:.me))
        let track = try #require(capture.snapshot.manifest.tracks.first)
        #expect(track.startOffsetMs == 150 && track.frames == 400)
        stage.recordedPCM?.offer(inputID:"mic",pcm:bytes,offsetMs:200)
        let sample = try #require(probe.snapshot.first)
        #expect(sample.source.id == track.id && sample.source.id != "mic")
        #expect(sample.source.startOffsetMs == 150 && sample.source.channels == 1)
        #expect(sample.offset == 200 && sample.pcm == bytes)
        stage.discard()
        stage.recordedPCM?.offer(inputID:"mic",pcm:bytes,offsetMs:300)
        #expect(probe.snapshot.count == 1)
        try await capture.finish()
    }
    @Test func browserObserverReceivesTheAdmittedSliceAndNewSpanAfterSelection() async throws {
        let root = try parent(); defer { try? FileManager.default.removeItem(at:root) }
        let capture = try OwnedBrowserCapture(parent:root,title:"Remote voice",microphone:true)
        let probe = AdmittedPCMProbe(); capture.pcmObservers.set(probe)
        let bytes = Data(repeating:0,count:1600)
        try capture.browserTrack(id:"voice",label:"Remote",kind:"remote",sampleRate:8000,channels:1)
        try capture.browserAudio(id:"voice",sequence:0,offsetMs:0,pcm:bytes)
        let first = try #require(probe.snapshot.first)
        try await capture.select(me:true,others:false,atMs:100)
        try capture.browserAudio(id:"voice",sequence:1,offsetMs:100,pcm:bytes)
        #expect(probe.snapshot.count == 1,"Excluded packets must not become picture data")
        try await capture.select(me:true,others:true,atMs:250)
        try capture.browserAudio(id:"voice",sequence:2,offsetMs:200,pcm:bytes)
        let last = try #require(probe.snapshot.last)
        #expect(probe.snapshot.count == 2)
        #expect(last.source.id != first.source.id && last.source.kind == "remote")
        #expect(last.source.startOffsetMs == 250 && last.offset == 250)
        #expect(last.pcm.count == 800,"Only the 400 retained mono frames may reach analysis")
        try await capture.finish()
    }
    @Test func twoCapturesWithTheSameBrowserSourceDoNotShareObservers() async throws {
        let root = try parent(); defer { try? FileManager.default.removeItem(at:root) }
        let first = try OwnedBrowserCapture(parent:root,title:"First",microphone:false)
        let second = try OwnedBrowserCapture(parent:root,title:"Second",microphone:false)
        let a = AdmittedPCMProbe(), b = AdmittedPCMProbe()
        first.pcmObservers.set(a); second.pcmObservers.set(b)
        for capture in [first,second] { try capture.browserTrack(id:"same-browser-source",label:"Voice",kind:"remote",sampleRate:8000,channels:1) }
        try first.browserAudio(id:"same-browser-source",sequence:0,offsetMs:50,pcm:Data([0,0]))
        #expect(a.snapshot.count == 1 && b.snapshot.isEmpty)
        try second.browserAudio(id:"same-browser-source",sequence:0,offsetMs:75,pcm:Data([0,0]))
        #expect(a.snapshot.count == 1 && b.snapshot.count == 1)
        #expect(a.snapshot.first?.source.id != b.snapshot.first?.source.id)
        try await first.finish(); try await second.finish()
    }
}
