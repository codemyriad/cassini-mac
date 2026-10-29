// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
import Foundation
import AVFoundation
import CassiniRecording
import CassiniKit
@testable import CassiniBrowserControl

final class OwnedCaptureTests: XCTestCase, @unchecked Sendable {
    func testFailedNativeSystemPublishesNoneOnceAndUserRetryPublishesActualSamples() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at:root) }
        let capture = try OwnedBrowserCapture(parent:root,title:"Native system lost",microphone:false,browser:false)
        let first = capture.nativeWriter(side:.others)
        try first.addTrack(id:"output",label:"Others",kind:"system",sampleRate:8000,channels:1)
        try first.appendNative(id:"output",pcm:Data(repeating:1,count:160),offsetMs:0)
        try first.finish(problem:"Generated system failure")
        try await capture.systemUnavailable(atMs:10)
        let count = capture.snapshot.manifest.events?.count
        try await capture.systemUnavailable(atMs:15)
        XCTAssertEqual(capture.snapshot.manifest.events?.count,count)
        XCTAssertEqual(capture.snapshot.manifest.events?.last?.source,"none")
        let retry = capture.nativeWriter(side:.others)
        try retry.addTrack(id:"output",label:"Others",kind:"system",sampleRate:8000,channels:1)
        try retry.appendNative(id:"output",pcm:Data(repeating:1,count:160),offsetMs:20)
        try retry.finish(problem:nil); try await capture.finish()
        XCTAssertEqual(capture.snapshot.manifest.events?.last?.source,"system")
        XCTAssertEqual(capture.snapshot.manifest.events?.last?.reason,"user")
    }
    func testNativeSourceAndUserResumePublishOnlyActualSystemBuffers() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at:root) }
        let capture = try OwnedBrowserCapture(parent:root,title:"Native",microphone:true,browser:false)
        XCTAssertTrue(capture.snapshot.needsSystem); XCTAssertEqual(capture.snapshot.manifest.source,"macos")
        XCTAssertEqual(capture.snapshot.manifest.events?.first?.source,"none")
        let first = capture.nativeWriter(side:.others)
        try first.addTrack(id:"output",label:"Others",kind:"system",sampleRate:8000,channels:1)
        XCTAssertEqual(capture.snapshot.manifest.events?.count,2)
        try first.appendNative(id:"output",pcm:Data(repeating:0,count:16000),offsetMs:0)
        try first.finish(problem:nil)
        XCTAssertEqual(capture.snapshot.manifest.events?.last?.reason,"start")
        try await capture.select(me:true,others:false,atMs:1000)
        try await capture.select(me:true,others:true,atMs:2000)
        let resumed = capture.nativeWriter(side:.others)
        try resumed.addTrack(id:"output",label:"Others",kind:"system",sampleRate:8000,channels:1)
        try resumed.appendNative(id:"output",pcm:Data(repeating:0,count:16000),offsetMs:2000)
        try resumed.finish(problem:nil); try await capture.finish()
        XCTAssertEqual(capture.snapshot.manifest.events?.last?.reason,"user")
        XCTAssertEqual(capture.snapshot.manifest.events?.last?.source,"system")
        XCTAssertTrue(capture.snapshot.manifest.tracks.allSatisfy { $0.sourceTrackId == nil })
    }
    func testMicResumeTrimsBufferedSamplesFromTheOffInterval() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at:root) }
        let capture = try OwnedBrowserCapture(parent:root,title:"Mic resume",microphone:true)
        let first = capture.nativeWriter(side:.me)
        try first.addTrack(id:"mic",label:"Me",kind:"microphone",sampleRate:8000,channels:1)
        try first.appendNative(id:"mic",pcm:Data(repeating:0,count:16000),offsetMs:0)
        try first.finish(problem:nil)
        try await capture.select(me:false,others:true,atMs:1000)
        try await capture.select(me:true,others:true,atMs:2000)
        let resumed = capture.nativeWriter(side:.me)
        try resumed.addTrack(id:"mic",label:"Me",kind:"microphone",sampleRate:8000,channels:1)
        try resumed.appendNative(id:"mic",pcm:Data(repeating:0x34,count:16000),offsetMs:1500)
        try resumed.finish(problem:nil); try await capture.finish()
        let track = try XCTUnwrap(capture.snapshot.manifest.tracks.last)
        XCTAssertEqual(track.startOffsetMs,2000); XCTAssertEqual(track.frames,4000)
    }
    func temporary() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CassiniOwnedTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700]); return root
    }
    func testTwoCapturesKeepIndependentFoldersClocksAndStop() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at:root) }
        let one = try OwnedBrowserCapture(parent:root,title:"One",microphone:false)
        let two = try OwnedBrowserCapture(parent:root,title:"Two",microphone:false)
        XCTAssertNotEqual(one.snapshot.manifest.id,two.snapshot.manifest.id)
        for capture in [one,two] { try capture.browserTrack(id:"same",label:"Remote",kind:"remote",sampleRate:8000,channels:1) }
        try one.browserAudio(id:"same",sequence:0,offsetMs:0,pcm:Data(repeating:0,count:16000))
        try two.browserAudio(id:"same",sequence:0,offsetMs:125,pcm:Data(repeating:0,count:16000))
        try await one.finish()
        try two.browserAudio(id:"same",sequence:1,offsetMs:1125,pcm:Data(repeating:0,count:16000))
        XCTAssertThrowsError(try one.browserAudio(id:"same",sequence:1,offsetMs:1000,pcm:Data([0,0])))
        try await two.finish()
        let a = try RecordingLoader.load(directory:one.snapshot.directory), b = try RecordingLoader.load(directory:two.snapshot.directory)
        XCTAssertEqual(a.tracks[0].frames,8000); XCTAssertEqual(b.tracks[0].frames,16000)
        XCTAssertEqual(b.tracks[0].startOffsetMs,125); XCTAssertEqual(a.state,"completed"); XCTAssertEqual(b.state,"completed")
    }
    func testMicAndBrowserShareOneFolderButFinishingMicDoesNotStopBrowser() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at:root) }
        let capture = try OwnedBrowserCapture(parent:root,title:"Both",microphone:true)
        let mic = capture.nativeWriter(side:.me)
        try mic.addTrack(id:"mic",label:"Me",kind:"microphone",sampleRate:8000,channels:1)
        try mic.appendNative(id:"mic",pcm:Data(repeating:0,count:16000),offsetMs:40)
        try capture.browserTrack(id:"remote",label:"Other",kind:"remote",sampleRate:8000,channels:1)
        try capture.browserAudio(id:"remote",sequence:0,offsetMs:0,pcm:Data(repeating:0,count:16000))
        try mic.finish(problem:nil)
        try capture.browserAudio(id:"remote",sequence:1,offsetMs:1000,pcm:Data(repeating:0,count:16000))
        try await capture.finish()
        let manifest = try RecordingLoader.load(directory:capture.snapshot.directory)
        XCTAssertEqual(manifest.tracks.count,2); XCTAssertEqual(manifest.tracks.filter { $0.kind == "microphone" }.first?.startOffsetMs,40)
        XCTAssertEqual(manifest.tracks.filter { $0.kind == "remote" }.first?.frames,16000)
        XCTAssertEqual(manifest.source,"chromium")
    }
    func testOthersOffOnCreatesDistinctSpansWithStableSourceAndExcludesTheGap() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at:root) }
        let capture = try OwnedBrowserCapture(parent:root,title:"Toggle",microphone:true)
        try capture.browserTrack(id:"source",label:"Original label",kind:"remote",sampleRate:8000,channels:1)
        try capture.browserAudio(id:"source",sequence:0,offsetMs:0,pcm:Data(repeating:0x12,count:16000))
        try await capture.select(me:true,others:false,atMs:1000)
        try capture.browserAudio(id:"source",sequence:1,offsetMs:1000,pcm:Data(repeating:0x56,count:16000))
        try await capture.select(me:true,others:true,atMs:2500)
        try capture.browserAudio(id:"source",sequence:2,offsetMs:2000,pcm:Data(repeating:0x34,count:16000))
        try await capture.finish()
        let manifest = try RecordingLoader.load(directory:capture.snapshot.directory)
        XCTAssertEqual(manifest.tracks.count,2)
        XCTAssertEqual(manifest.tracks.map(\.sourceTrackId),["source","source"])
        XCTAssertNotEqual(manifest.tracks[0].id,manifest.tracks[1].id); XCTAssertNotEqual(manifest.tracks[0].file,manifest.tracks[1].file)
        XCTAssertEqual(manifest.tracks[0].endOffsetMs,1000)
        XCTAssertEqual(manifest.tracks[1].startOffsetMs,2500); XCTAssertEqual(manifest.tracks[1].frames,4000)
        for track in manifest.tracks {
            let pcm = try Data(contentsOf:capture.snapshot.directory.appendingPathComponent(track.file)).dropFirst(44)
            XCTAssertFalse(pcm.contains(0x56),"Excluded source bytes must never be written")
        }
        XCTAssertEqual(CaptureSourceState(events:manifest.events ?? [],atMs:1500).source,"none")
        XCTAssertEqual(CaptureSourceState(events:manifest.events ?? [],atMs:2500).source,"browser")
    }
    func testLostBrowserKeepsMicAndSystemFallbackInTheSameFolderWithoutRestoring() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at:root) }
        let capture = try OwnedBrowserCapture(parent:root,title:"Fallback",microphone:true)
        let mic = capture.nativeWriter(side:.me)
        try mic.addTrack(id:"mic",label:"Me",kind:"microphone",sampleRate:8000,channels:1)
        try mic.appendNative(id:"mic",pcm:Data(repeating:0,count:16000),offsetMs:0)
        try capture.browserTrack(id:"remote",label:"Remote",kind:"remote",sampleRate:8000,channels:1)
        try capture.browserAudio(id:"remote",sequence:0,offsetMs:0,pcm:Data(repeating:0,count:16000))
        try capture.browserLost(atMs:1000)
        XCTAssertTrue(capture.snapshot.needsSystem)
        let system = capture.nativeWriter(side:.others)
        try system.addTrack(id:"output",label:"Computer",kind:"system",sampleRate:8000,channels:1)
        XCTAssertFalse(capture.snapshot.manifest.tracks.contains { $0.kind == "system" })
        try system.appendNative(id:"output",pcm:Data(repeating:0,count:16000),offsetMs:1000)
        XCTAssertFalse(capture.snapshot.needsSystem)
        try mic.appendNative(id:"mic",pcm:Data(repeating:0,count:16000),offsetMs:1000)
        // Late browser packets cannot restore it or duplicate computer sound.
        try capture.browserAudio(id:"remote",sequence:1,offsetMs:1000,pcm:Data(repeating:0x77,count:16000))
        XCTAssertThrowsError(try capture.browserTrack(id:"new",label:"New",kind:"remote",sampleRate:8000,channels:1))
        try mic.finish(problem:nil); try system.finish(problem:nil); try await capture.finish()
        let manifest = try RecordingLoader.load(directory:capture.snapshot.directory)
        XCTAssertEqual(manifest.tracks.count,3)
        XCTAssertEqual(manifest.tracks.first { $0.kind == "microphone" }?.frames,16000)
        let fallback = try XCTUnwrap(manifest.tracks.first { $0.kind == "system" })
        XCTAssertEqual(fallback.startOffsetMs,1000); XCTAssertNil(fallback.sourceTrackId)
        XCTAssertEqual(manifest.events?.last?.source,"system"); XCTAssertEqual(manifest.events?.last?.reason,"lost")
        XCTAssertEqual(manifest.events?.last?.atMs,fallback.startOffsetMs)
    }
    func testMicrophoneFrameClockCannotShiftBrowserLossOrSystemStart() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at:root) }
        let capture = try OwnedBrowserCapture(parent:root,title:"Separate clocks",microphone:true)
        let mic = capture.nativeWriter(side:.me)
        try mic.addTrack(id:"mic",label:"Me",kind:"microphone",sampleRate:8000,channels:1)
        try mic.appendNative(id:"mic",pcm:Data(repeating:0,count:16000),offsetMs:100)
        try capture.browserLost(atMs:1000)
        let system = capture.nativeWriter(side:.others)
        try system.addTrack(id:"system",label:"Others",kind:"system",sampleRate:8000,channels:1)
        try system.appendNative(id:"system",pcm:Data(repeating:0,count:16000),offsetMs:1000)
        try mic.finish(problem:nil); try system.finish(problem:nil); try await capture.finish()
        let manifest = try RecordingLoader.load(directory:capture.snapshot.directory)
        XCTAssertEqual(manifest.events?.last?.atMs,1000)
        XCTAssertEqual(manifest.tracks.first { $0.kind == "system" }?.startOffsetMs,1000)
        XCTAssertEqual(manifest.tracks.first { $0.kind == "system" }?.frames,8000)
    }
    func testNoMicrophoneChoiceCannotCreateOrWriteANativeMic() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at:root) }
        let capture = try OwnedBrowserCapture(parent:root,title:"Others",microphone:false)
        let mic = capture.nativeWriter(side:.me)
        try mic.addTrack(id:"mic",label:"Mic",kind:"microphone",sampleRate:8000,channels:1)
        try mic.appendNative(id:"mic",pcm:Data(repeating:0x7f,count:16000),offsetMs:0)
        try mic.finish(problem:nil)
        XCTAssertTrue(capture.snapshot.manifest.tracks.isEmpty)
        XCTAssertThrowsError(try capture.browserTrack(id:"sender",label:"Page microphone",kind:"local",sampleRate:8000,channels:1))
        try await capture.finish()
        XCTAssertTrue(try RecordingLoader.load(directory:capture.snapshot.directory).tracks.isEmpty)
    }
    func testMalformedSourceAndClockFailuresDoNotAffectAnotherCapture() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at:root) }
        let bad = try OwnedBrowserCapture(parent:root,title:"Bad",microphone:false)
        let good = try OwnedBrowserCapture(parent:root,title:"Good",microphone:false)
        for capture in [bad,good] { try capture.browserTrack(id:"r",label:"Remote",kind:"remote",sampleRate:8000,channels:1) }
        XCTAssertThrowsError(try bad.browserAudio(id:"r",sequence:1,offsetMs:0,pcm:Data([0,0])))
        XCTAssertThrowsError(try bad.browserAudio(id:"r",sequence:0,offsetMs:.infinity,pcm:Data([0,0])))
        XCTAssertThrowsError(try bad.browserAudio(id:"r",sequence:0,offsetMs:0,pcm:Data([0])))
        try good.browserAudio(id:"r",sequence:0,offsetMs:0,pcm:Data(repeating:0,count:16000))
        try await good.finish(); XCTAssertEqual(good.snapshot.manifest.state,"completed")
        try await bad.finish(problem:"Generated invalid source")
    }
    func testSourceArrivingWhileOthersOffIsEndedWithoutPersistingPCM() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at:root) }
        let capture = try OwnedBrowserCapture(parent:root,title:"Off",microphone:true)
        try await capture.select(me:true,others:false,atMs:1000)
        try capture.browserTrack(id:"late",label:"Late",kind:"remote",sampleRate:8000,channels:1)
        try capture.browserAudio(id:"late",sequence:0,offsetMs:1000,pcm:Data(repeating:0x7e,count:16000))
        let manifest = try RecordingLoader.load(directory:capture.snapshot.directory)
        XCTAssertEqual(manifest.tracks[0].ended,true); XCTAssertEqual(manifest.tracks[0].frames,0)
        XCTAssertEqual(try Data(contentsOf:capture.snapshot.directory.appendingPathComponent(manifest.tracks[0].file)).count,44)
        try await capture.finish()
    }
}
