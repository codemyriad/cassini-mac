// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
import Foundation
import AVFoundation
import CassiniRecording
import CassiniKit
@testable import CassiniBrowserControl

@MainActor private final class GeneratedInput: CaptureInput {
    let kind: String
    var authorized = 0, starts = 0, stops = 0
    var permission: CheckedContinuation<Void,Error>?
    var holdPermission = false, denied = false
    var sink: RecordingSink?
    var failure: (@Sendable (String) -> Void)?
    var failingStart = false, failingAfterSamples = false
    var onStop: (() -> Void)?
    var onStart: (() -> Void)?
    var firstAt: Double = 0
    let origin: UInt64
    init(_ kind: String, origin: UInt64) { self.kind = kind; self.origin = origin }
    func authorize() async throws {
        authorized += 1
        if denied { throw CocoaError(.fileReadNoPermission) }
        if holdPermission { try await withCheckedThrowingContinuation { permission = $0 } }
    }
    func start(sink: RecordingSink, failure: @escaping @Sendable (String) -> Void) throws {
        if failingStart { throw CocoaError(.fileReadNoPermission) }
        self.sink = sink; self.failure = failure; starts += 1; emit(at:firstAt); onStart?()
        if failingAfterSamples { throw CocoaError(.fileReadNoPermission) }
    }
    func emit(at seconds: Double) {
        let format = AVAudioFormat(standardFormatWithSampleRate:8000,channels:1)!
        let buffer = AVAudioPCMBuffer(pcmFormat:format,frameCapacity:800)!
        buffer.frameLength = 800
        for index in 0..<800 { buffer.floatChannelData![0][index] = 0.25 }
        sink?.receive(buffer,hostTime:origin + AVAudioTime.hostTime(forSeconds:seconds),id:kind,label:kind,kind:kind)
    }
    func stop() { stops += 1; sink = nil; onStop?() }
}
final class InputLifecycleTests: XCTestCase, @unchecked Sendable {
    @MainActor private func returnFixture() async throws -> (URL,OwnedBrowserCapture,GeneratedInput,GeneratedInput,CaptureInputLifecycle) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let owner = try OwnedBrowserCapture(parent:root,title:"Return",microphone:true,managedBrowser:true)
        try owner.browserTrack(id:"before",label:"Remote",kind:"remote",sampleRate:8000,channels:1)
        try owner.browserAudio(id:"before",sequence:0,offsetMs:0,pcm:Data(repeating:1,count:1600))
        let origin = AVAudioTime.hostTime(forSeconds:ProcessInfo.processInfo.systemUptime)
        let mic = GeneratedInput("microphone",origin:origin), system = GeneratedInput("system",origin:origin)
        system.firstAt = 2
        let inputs = CaptureInputLifecycle(capture:owner,originHostTime:origin,microphone:{ mic },system:{ system },failure:{ _ in })
        try await inputs.start()
        if let sink = mic.sink { await Task.detached { sink.flush() }.value }
        return (root,owner,mic,system,inputs)
    }
    private func offerReturn(_ owner: OwnedBrowserCapture, id: String = "after", atMs: Double = 2500) throws {
        try owner.browserTrack(id:id,label:"Returned",kind:"remote",sampleRate:8000,channels:1)
        try owner.browserAudio(id:id,sequence:0,offsetMs:atMs,pcm:Data(repeating:2,count:1600))
    }
    @MainActor private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(2)
        while !condition(), Date() < deadline { try await Task.sleep(for:.milliseconds(5)) }
        guard condition() else { throw BrowserIPCError.timeout }
    }
    @MainActor func testBrowserReturnCancelsPendingFallbackWithoutAnOSReplyOrALateSystemStart() async throws {
        let (root,owner,mic,system,inputs) = try await returnFixture()
        defer { system.permission?.resume(); system.permission = nil; try? FileManager.default.removeItem(at:root) }
        try owner.browserLost(atMs:1000,transportAlive:true)
        system.holdPermission = true
        var fallbackDone = false
        let pending = Task { () -> Bool in
            defer { fallbackDone = true }
            do { try await inputs.fallback(); return false } catch { return error is CancellationError }
        }
        try await waitUntil { system.permission != nil }
        inputs.cancelSourceChange()
        try offerReturn(owner,id:"returned-during-permission")
        var restored = false
        let returning = Task { try await inputs.restoreBrowser(atMs:3000); restored = true }
        // Keep the permission unanswered throughout the actual restoration.
        try await waitUntil { restored && fallbackDone }
        XCTAssertTrue(owner.snapshot.browserAlive); XCTAssertEqual(system.starts,0)
        XCTAssertEqual(mic.stops,0); XCTAssertTrue(inputs.failedSides.isEmpty)
        let cancelled = await pending.value
        XCTAssertTrue(cancelled)
        try await returning.value
        system.permission?.resume(); system.permission = nil
        await Task.yield()
        try await inputs.update()
        XCTAssertEqual(system.starts,0,"A late grant belongs to the cancelled request")
        XCTAssertFalse(owner.snapshot.manifest.tracks.contains { $0.kind == "system" })
        try await inputs.stop(); try await owner.finish()
    }
    @MainActor func testRepeatedPageChangesCancelWaitersButKeepOnlyOnePendingOSRequest() async throws {
        let (root,owner,mic,system,inputs) = try await returnFixture()
        defer { system.permission?.resume(); system.permission = nil; try? FileManager.default.removeItem(at:root) }
        try owner.browserLost(atMs:1000,transportAlive:true)
        system.holdPermission = true
        for _ in 0..<4 {
            var done = false
            let pending = Task { () -> Bool in
                defer { done = true }
                do { try await inputs.fallback(); return false } catch { return error is CancellationError }
            }
            try await waitUntil { system.permission != nil }
            // Let the new waiter enter the shared outstanding authorization.
            for _ in 0..<10 { await Task.yield() }
            inputs.cancelSourceChange()
            try await waitUntil { done }
            let cancelled = await pending.value
            XCTAssertTrue(cancelled)
            XCTAssertEqual(system.authorized,1)
        }
        system.permission?.resume(); system.permission = nil
        await Task.yield()
        try await inputs.update()
        XCTAssertEqual(system.starts,0); XCTAssertEqual(mic.stops,0)
        XCTAssertFalse(owner.snapshot.fallbackRequested)
        XCTAssertTrue(inputs.failedSides.isEmpty)
        try await inputs.stop(); try await owner.finish()
    }
    @MainActor func testCurrentFallbackCanUseTheGrantFromAnEarlierCancelledWaiter() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let owner = try OwnedBrowserCapture(parent:root,title:"Shared authorization",microphone:false,managedBrowser:true)
        let origin = AVAudioTime.hostTime(forSeconds:ProcessInfo.processInfo.systemUptime)
        let mic = GeneratedInput("microphone",origin:origin), oldSystem = GeneratedInput("system",origin:origin)
        defer { oldSystem.permission?.resume(); oldSystem.permission = nil; try? FileManager.default.removeItem(at:root) }
        // Only the first candidate's OS request stays alive; its late reply
        // must start the currently selected candidate, never the cancelled one.
        let newSystem = GeneratedInput("system",origin:origin); newSystem.firstAt = 2.1
        var candidates = [oldSystem,newSystem]
        let inputs = CaptureInputLifecycle(capture:owner,originHostTime:origin,microphone:{ mic },system:{ candidates.removeFirst() },failure:{ _ in })
        oldSystem.holdPermission = true
        try owner.browserLost(atMs:1000,transportAlive:true)
        var cancelled = false
        let first = Task { do { try await inputs.fallback() } catch { cancelled = error is CancellationError } }
        try await waitUntil { oldSystem.permission != nil }
        inputs.cancelSourceChange()
        try await waitUntil { cancelled }
        await first.value
        var ready = false
        let second = Task { try await inputs.fallback(); ready = true }
        try await waitUntil { candidates.isEmpty }
        XCTAssertEqual(newSystem.authorized,0)
        oldSystem.permission?.resume(); oldSystem.permission = nil
        try await waitUntil { ready }
        try await second.value
        XCTAssertEqual(oldSystem.starts,0); XCTAssertEqual(newSystem.starts,1)
        XCTAssertTrue(owner.snapshot.usingSystem); XCTAssertTrue(inputs.failedSides.isEmpty)
        try await inputs.stop(); try await owner.finish()
    }

    @MainActor func testNavigationDuringSystemDrainRejectsRestorationAndResumesTheSameWriter() async throws {
        let (root,owner,mic,system,inputs) = try await returnFixture()
        defer { try? FileManager.default.removeItem(at:root) }
        try owner.browserLost(atMs:1000,transportAlive:true); try await inputs.fallback()
        try offerReturn(owner)
        let oldSystem = try XCTUnwrap(owner.snapshot.manifest.tracks.first { $0.kind == "system" }?.id)
        system.firstAt = 2.1
        system.onStop = { inputs.cancelSourceChange() }
        do { try await inputs.restoreBrowser(atMs:3000); XCTFail("Navigation must invalidate the pending return") }
        catch { XCTAssertTrue(error is CancellationError) }
        system.onStop = nil
        XCTAssertTrue(owner.snapshot.usingSystem); XCTAssertFalse(owner.snapshot.browserAlive)
        XCTAssertEqual(mic.stops,0); XCTAssertEqual(system.starts,2)
        XCTAssertEqual(owner.snapshot.manifest.tracks.filter { $0.kind == "system" }.map(\.id),[oldSystem])
        XCTAssertFalse(owner.snapshot.manifest.events?.contains { $0.reason == "restored" } ?? true)
        try await inputs.restoreBrowser(atMs:3200)
        XCTAssertTrue(owner.snapshot.browserAlive)
        try await inputs.stop(); try await owner.finish()
        XCTAssertEqual(owner.snapshot.manifest.tracks.first { $0.id == oldSystem }?.frames,1600)
    }
    @MainActor func testPageClosesDuringPreparedSystemStartDiscardsEveryBufferedSample() async throws {
        let (root,owner,mic,system,inputs) = try await returnFixture()
        defer { try? FileManager.default.removeItem(at:root) }
        try owner.browserLost(atMs:1000,transportAlive:true)
        system.onStart = { inputs.cancelSourceChange() }
        do { try await inputs.fallback(); XCTFail("Closed page must reject the candidate") }
        catch { XCTAssertTrue(error is CancellationError) }
        system.onStart = nil
        XCTAssertEqual(system.starts,1); XCTAssertEqual(system.stops,1); XCTAssertEqual(mic.stops,0)
        XCTAssertTrue(inputs.failedSides.isEmpty); XCTAssertFalse(owner.snapshot.fallbackRequested)
        XCTAssertFalse(owner.snapshot.manifest.tracks.contains { $0.kind == "system" })
        XCTAssertFalse(owner.snapshot.manifest.events?.contains { $0.source == "system" } ?? true)
        try await inputs.update()
        XCTAssertEqual(system.starts,1,"Managed update must not restart a cancelled source")
        try await inputs.stop(); try await owner.finish()
    }

    @MainActor func testChangedObservationRejectsQueuedLossAndFallbackBeforeAnyDeviceWork() async throws {
        let (root,owner,mic,system,inputs) = try await returnFixture()
        defer { try? FileManager.default.removeItem(at:root) }
        let revision = inputs.sourceRevision
        inputs.cancelSourceChange()
        do { try await inputs.observeBrowserLoss(atMs:1000,transportAlive:true,revision:revision); XCTFail("Stale loss") }
        catch { XCTAssertTrue(error is CancellationError) }
        do { try await inputs.fallback(revision:revision); XCTFail("Stale fallback") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(owner.snapshot.browserAlive); XCTAssertEqual(system.authorized,0); XCTAssertEqual(mic.stops,0)
        // Revalidation also happens on the owner's I/O queue, not just before enqueue.
        XCTAssertThrowsError(try owner.browserLost(atMs:1000,transportAlive:true,allowed:{ false }))
        try owner.browserLost(atMs:1000,transportAlive:true)
        try offerReturn(owner)
        do { try await owner.restoreBrowser(atMs:3000,allowed:{ false }); XCTFail("Stale I/O transaction") }
        catch { XCTAssertTrue(error is CancellationError) }
        do { try await owner.requestSystemFallback(allowed:{ false }); XCTFail("Stale fallback publication") }
        catch { XCTAssertTrue(error is CancellationError) }
        let stage = StagedNativeWriter()
        try stage.addTrack(id:"discarded",label:"Stale candidate",kind:"system",sampleRate:8000,channels:1)
        try stage.appendNative(id:"discarded",pcm:Data(repeating:1,count:1600),offsetMs:2000)
        do { try await owner.activateNative(stage,side:.others,allowed:{ false }); XCTFail("Stale PCM admission") }
        catch { XCTAssertTrue(error is CancellationError) }
        stage.discard()
        XCTAssertFalse(owner.snapshot.manifest.tracks.contains { $0.kind == "system" })
        XCTAssertFalse(owner.snapshot.browserAlive); XCTAssertFalse(owner.snapshot.fallbackRequested)
        XCTAssertFalse(owner.snapshot.manifest.events?.contains { $0.reason == "restored" } ?? true)
        try await inputs.stop(); try await owner.finish()
    }

    @MainActor func testManagedFallbackAndReturnKeepTheFolderClockMicAndActualSourceSpans() async throws {
        let (root,owner,mic,system,inputs) = try await returnFixture()
        defer { try? FileManager.default.removeItem(at:root) }
        let id = owner.snapshot.manifest.id, folder = owner.snapshot.directory
        try owner.browserLost(atMs:1000,transportAlive:true)
        try await inputs.update()
        XCTAssertEqual(system.starts,0,"Managed loss must wait for the policy grace")
        try await inputs.fallback()
        XCTAssertTrue(owner.snapshot.usingSystem)
        try owner.browserTrack(id:"after",label:"Remote",kind:"remote",sampleRate:8000,channels:1)
        try owner.browserAudio(id:"after",sequence:0,offsetMs:2500,pcm:Data(repeating:2,count:1600))
        XCTAssertTrue(owner.snapshot.restoreReady)
        try await inputs.restoreBrowser(atMs:3000)
        XCTAssertTrue(owner.snapshot.browserAlive); XCTAssertFalse(owner.snapshot.usingSystem)
        XCTAssertEqual(mic.starts,1); XCTAssertEqual(mic.stops,0)
        XCTAssertEqual(system.starts,1); XCTAssertEqual(system.stops,1)
        let cutover = try XCTUnwrap(owner.snapshot.manifest.events?.last(where:{ $0.reason == "restored" })?.atMs)
        let firstAfter = ceil(cutover)+100
        try owner.browserAudio(id:"after",sequence:1,offsetMs:floor(cutover)-100,pcm:Data(repeating:3,count:1600))
        try owner.browserAudio(id:"after",sequence:2,offsetMs:firstAfter,pcm:Data(repeating:4,count:1600))
        mic.emit(at:0.1)
        try await inputs.stop(); try await owner.finish()
        XCTAssertEqual(owner.snapshot.manifest.id,id); XCTAssertEqual(owner.snapshot.directory,folder)
        let manifest = try RecordingLoader.load(directory:folder)
        XCTAssertEqual(manifest.events?.last(where:{ $0.type == "othersSource" })?.reason,"restored")
        let state = CaptureSourceState(events:manifest.events ?? [],atMs:manifest.events?.last?.atMs ?? 0)
        XCTAssertEqual(state.source,"browser"); XCTAssertEqual(state.me,true); XCTAssertEqual(state.others,true)
        let resumed = try XCTUnwrap(manifest.tracks.last { $0.sourceTrackId == "after" && $0.frames > 0 })
        XCTAssertEqual(resumed.startOffsetMs,firstAfter); XCTAssertEqual(resumed.frames,800)
        XCTAssertEqual(manifest.tracks.first { $0.kind == "microphone" }?.frames,1600)
        XCTAssertTrue(manifest.tracks.filter { $0.kind == "system" }.allSatisfy { $0.ended == true })
    }
    @MainActor func testBrowserReturningBeforeFallbackRecordsWithoutInventingASystemRestoration() async throws {
        let (root,owner,mic,system,inputs) = try await returnFixture()
        defer { try? FileManager.default.removeItem(at:root) }
        try owner.browserLost(atMs:1000,transportAlive:true)
        try offerReturn(owner,id:"quick",atMs:1200)
        try await inputs.restoreBrowser(atMs:1500)
        try owner.browserAudio(id:"quick",sequence:1,offsetMs:1600,pcm:Data(repeating:3,count:1600))
        XCTAssertEqual(system.starts,0); XCTAssertEqual(mic.stops,0)
        try await inputs.stop(); try await owner.finish()
        let manifest = try RecordingLoader.load(directory:owner.snapshot.directory)
        XCTAssertFalse(manifest.tracks.contains { $0.kind == "system" })
        XCTAssertFalse(manifest.events?.contains { $0.reason == "restored" } ?? true)
        XCTAssertEqual(manifest.tracks.last { $0.sourceTrackId == "quick" && $0.frames > 0 }?.frames,800)
        XCTAssertEqual(CaptureSourceState(events:manifest.events ?? [],atMs:2000).source,"browser")
    }

    @MainActor func testNavigationRequiresFreshPCMFromANewDocumentSource() async throws {
        let (root,owner,_,system,inputs) = try await returnFixture()
        defer { try? FileManager.default.removeItem(at:root) }
        try owner.browserLost(atMs:1000,transportAlive:true)
        try await inputs.fallback()
        try owner.browserAudio(id:"before",sequence:1,offsetMs:2500,pcm:Data(repeating:1,count:1600))
        XCTAssertLessThan(owner.snapshot.browserReturnPCMAt ?? .infinity,2600,"PCM before the observed return cannot justify restoring the browser")
        try owner.browserTrack(id:"new-document",label:"New document",kind:"remote",sampleRate:8000,channels:1)
        XCTAssertLessThan(owner.snapshot.browserReturnPCMAt ?? .infinity,2600,"A format announcement is not yet fresh PCM")
        do { try await inputs.restoreBrowser(atMs:3000,notBeforeMs:2600); XCTFail("Working system input must stay on") } catch {}
        XCTAssertEqual(system.stops,0)
        try owner.browserAudio(id:"new-document",sequence:0,offsetMs:2600,pcm:Data(repeating:1,count:1600))
        XCTAssertTrue(owner.snapshot.restoreReady)
        try await inputs.restoreBrowser(atMs:3000,notBeforeMs:2600)
        XCTAssertEqual(system.stops,1)
        try await inputs.select(me:true,others:false,atMs:4000)
        try await inputs.select(me:true,others:true,atMs:5000)
        XCTAssertEqual(owner.snapshot.manifest.tracks.filter { $0.kind == "remote" && $0.ended != true }.map(\.sourceTrackId),["new-document"])
        try await inputs.stop(); try await owner.finish()
    }
    @MainActor func testNetworkRecoveryCanResumeTheSameSourceWithAFreshSpan() async throws {
        let (root,owner,_,_,inputs) = try await returnFixture()
        defer { try? FileManager.default.removeItem(at:root) }
        try owner.browserLost(atMs:1000,transportAlive:true)
        try await inputs.fallback()
        try owner.browserAudio(id:"before",sequence:1,offsetMs:2500,pcm:Data(repeating:1,count:1600))
        XCTAssertTrue(owner.snapshot.restoreReady)
        try await inputs.restoreBrowser(atMs:3000)
        try owner.browserAudio(id:"before",sequence:2,offsetMs:3200,pcm:Data(repeating:1,count:1600))
        try await inputs.stop(); try await owner.finish()
        let spans = owner.snapshot.manifest.tracks.filter { $0.sourceTrackId == "before" }
        XCTAssertEqual(spans.count,2); XCTAssertEqual(spans.last?.frames,800)
        XCTAssertNotEqual(spans.first?.id,spans.last?.id)
    }

    @MainActor func testASecondReturnedSourceWithLaterPCMStillGetsItsOwnFreshSpan() async throws {
        let (root,owner,_,_,inputs) = try await returnFixture()
        defer { try? FileManager.default.removeItem(at:root) }
        try owner.browserLost(atMs:1000,transportAlive:true); try await inputs.fallback()
        try offerReturn(owner)
        try owner.browserTrack(id:"late",label:"Second remote",kind:"remote",sampleRate:8000,channels:1)
        try await inputs.restoreBrowser(atMs:3000)
        try owner.browserAudio(id:"after",sequence:1,offsetMs:3200,pcm:Data(repeating:2,count:1600))
        try owner.browserAudio(id:"late",sequence:0,offsetMs:3300,pcm:Data(repeating:3,count:1600))
        try await inputs.stop(); try await owner.finish()
        XCTAssertEqual(owner.snapshot.manifest.tracks.last { $0.sourceTrackId == "after" && $0.frames > 0 }?.frames,800)
        XCTAssertEqual(owner.snapshot.manifest.tracks.last { $0.sourceTrackId == "late" && $0.frames > 0 }?.frames,800)
        XCTAssertEqual(owner.snapshot.manifest.events?.filter { $0.reason == "restored" }.count,1)
    }

    @MainActor func testPreparedDriverFailureBeforeActivationCannotPublishItsBufferedSystemPCM() async throws {
        let (root,owner,mic,_,inputs) = try await returnFixture()
        defer { try? FileManager.default.removeItem(at:root) }
        try owner.browserLost(atMs:1000,transportAlive:true)
        let stage = StagedNativeWriter()
        try stage.addTrack(id:"output",label:"Prepared",kind:"system",sampleRate:8000,channels:1)
        try stage.appendNative(id:"output",pcm:Data(repeating:1,count:1600),offsetMs:2000)
        stage.fail("Generated failure before activation")
        XCTAssertThrowsError(try stage.activate(owner.nativeWriter(side:.others)))
        XCTAssertFalse(owner.snapshot.usingSystem)
        XCTAssertFalse(owner.snapshot.manifest.tracks.contains { $0.kind == "system" })
        XCTAssertEqual(mic.stops,0)
        try await inputs.stop(); try await owner.finish()
    }

    @MainActor func testRejectedReturnResumesTheExistingSystemSpanAndKeepsMicRunning() async throws {
        let (root,owner,mic,system,inputs) = try await returnFixture()
        defer { try? FileManager.default.removeItem(at:root) }
        try owner.browserLost(atMs:1000,transportAlive:true); try await inputs.fallback()
        for index in 0..<(64-owner.snapshot.manifest.tracks.count) { try offerReturn(owner,id:"after-\(index)") }
        XCTAssertEqual(owner.snapshot.manifest.tracks.count,64)
        let events = owner.snapshot.manifest.events?.count
        system.firstAt = 2.1
        do { try await inputs.restoreBrowser(atMs:3000); XCTFail("Track limit must reject restoration") } catch {}
        XCTAssertFalse(owner.snapshot.browserAlive); XCTAssertTrue(owner.snapshot.usingSystem)
        XCTAssertEqual(owner.snapshot.manifest.events?.count,events)
        XCTAssertEqual(mic.stops,0); XCTAssertEqual(system.starts,2)
        mic.emit(at:0.1)
        try await inputs.stop(); try await owner.finish()
        XCTAssertEqual(owner.snapshot.manifest.tracks.filter { $0.kind == "system" }.count,1)
        XCTAssertEqual(owner.snapshot.manifest.tracks.first { $0.kind == "system" }?.frames,1600)
        XCTAssertEqual(owner.snapshot.manifest.tracks.first { $0.kind == "microphone" }?.frames,1600)
        XCTAssertFalse(owner.snapshot.manifest.events?.contains { $0.reason == "restored" } ?? true)
    }
    @MainActor func testUnwritableRestoreCheckpointKeepsTheExistingSystemAndMicWriters() async throws {
        let (root,owner,mic,system,inputs) = try await returnFixture()
        defer { try? FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:owner.snapshot.directory.path); try? FileManager.default.removeItem(at:root) }
        try owner.browserLost(atMs:1000,transportAlive:true); try await inputs.fallback()
        try offerReturn(owner)
        let events = owner.snapshot.manifest.events?.count
        let files = try FileManager.default.contentsOfDirectory(atPath:owner.snapshot.directory.path).sorted()
        system.firstAt = 2.1
        try FileManager.default.setAttributes([.posixPermissions:0o500],ofItemAtPath:owner.snapshot.directory.path)
        do { try await inputs.restoreBrowser(atMs:3000); XCTFail("The actual private directory cannot accept a new source checkpoint") } catch {}
        try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:owner.snapshot.directory.path)
        XCTAssertFalse(owner.snapshot.browserAlive); XCTAssertTrue(owner.snapshot.usingSystem)
        XCTAssertEqual(owner.snapshot.manifest.events?.count,events)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath:owner.snapshot.directory.path).sorted(),files)
        XCTAssertEqual(system.starts,2); XCTAssertEqual(mic.stops,0)
        mic.emit(at:0.1)
        try await inputs.stop(); try await owner.finish()
        XCTAssertEqual(owner.snapshot.manifest.tracks.first { $0.kind == "system" }?.frames,1600)
        XCTAssertEqual(owner.snapshot.manifest.tracks.first { $0.kind == "microphone" }?.frames,1600)
    }

    @MainActor func testOthersOffStaysOffOnReturnAndAnExplicitOnUsesTheBrowserWithoutStartingSystemAgain() async throws {
        let (root,owner,mic,system,inputs) = try await returnFixture()
        defer { try? FileManager.default.removeItem(at:root) }
        try owner.browserLost(atMs:1000,transportAlive:true); try await inputs.fallback()
        try await inputs.select(me:true,others:false,atMs:3000)
        try offerReturn(owner,atMs:4000)
        do { try await inputs.restoreBrowser(atMs:4000); XCTFail("The others must remain off") } catch {}
        XCTAssertFalse(owner.snapshot.others)
        XCTAssertEqual(owner.snapshot.manifest.events?.last(where:{ $0.type == "othersSource" })?.source,"none")
        try await inputs.select(me:true,others:true,atMs:5000)
        XCTAssertTrue(owner.snapshot.browserAlive); XCTAssertTrue(owner.snapshot.others)
        XCTAssertEqual(system.starts,1); XCTAssertEqual(mic.stops,0)
        XCTAssertEqual(owner.snapshot.manifest.events?.last(where:{ $0.type == "othersSource" })?.reason,"user")
        try await inputs.stop(); try await owner.finish()
    }
    @MainActor func testRejectedFallbackDoesNotPublishSystemOrStopMicAndUserCanRetry() async throws {
        let (root,owner,mic,system,inputs) = try await returnFixture()
        defer { try? FileManager.default.removeItem(at:root) }
        try owner.browserLost(atMs:1000,transportAlive:true)
        system.failingAfterSamples = true
        do { try await inputs.fallback(); XCTFail("Generated system start must fail") } catch {}
        XCTAssertFalse(owner.snapshot.usingSystem); XCTAssertEqual(mic.stops,0)
        XCTAssertFalse(owner.snapshot.manifest.events?.contains { $0.source == "system" } ?? true)
        system.failingAfterSamples = false; try await inputs.retry(.others)
        XCTAssertTrue(owner.snapshot.usingSystem); XCTAssertEqual(mic.starts,1)
        try await inputs.stop(); try await owner.finish()
    }
    @MainActor func testADeadOriginalTransportCannotRestoreUsingAPagesDiscovery() async throws {
        let (root,owner,_,system,inputs) = try await returnFixture()
        defer { try? FileManager.default.removeItem(at:root) }
        try owner.browserLost(atMs:1000); try await inputs.fallback()
        XCTAssertFalse(owner.snapshot.transportAlive)
        XCTAssertThrowsError(try owner.browserTrack(id:"impostor",label:"Remote",kind:"remote",sampleRate:8000,channels:1))
        do { try await inputs.restoreBrowser(atMs:3000); XCTFail("A dead native transport cannot return") } catch {}
        XCTAssertTrue(owner.snapshot.usingSystem); XCTAssertEqual(system.stops,0)
        try await inputs.stop(); try await owner.finish()
    }

    @MainActor func testRestoringOneMeetingCannotChangeOrStopTheOtherMeetingsFallback() async throws {
        let (root1,one,mic1,system1,input1) = try await returnFixture()
        let (root2,two,mic2,system2,input2) = try await returnFixture()
        defer { try? FileManager.default.removeItem(at:root1); try? FileManager.default.removeItem(at:root2) }
        try one.browserLost(atMs:1000,transportAlive:true); try two.browserLost(atMs:1000,transportAlive:true)
        try await input1.fallback(); try await input2.fallback()
        try offerReturn(one,id:"returned")
        try await input1.restoreBrowser(atMs:3000)
        XCTAssertTrue(one.snapshot.browserAlive); XCTAssertTrue(two.snapshot.usingSystem)
        XCTAssertEqual(system1.stops,1); XCTAssertEqual(system2.stops,0)
        XCTAssertEqual(mic1.stops,0); XCTAssertEqual(mic2.stops,0)
        try await input1.stop(); try await one.finish()
        XCTAssertEqual(two.snapshot.phase,.recording)
        system2.emit(at:2.1); mic2.emit(at:0.1)
        try await input2.stop(); try await two.finish()
        XCTAssertNotEqual(one.snapshot.directory,two.snapshot.directory)
        XCTAssertEqual(two.snapshot.manifest.tracks.first { $0.kind == "system" }?.frames,1600)
        XCTAssertFalse(two.snapshot.manifest.events?.contains { $0.reason == "restored" } ?? true)
    }

    @MainActor func testReplacementFailureDuringOldInputDrainRollsBackToItsExistingWriter() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let owner = try OwnedBrowserCapture(parent:root,title:"Candidate lost during drain",microphone:true,browser:false)
        let origin = AVAudioTime.hostTime(forSeconds:ProcessInfo.processInfo.systemUptime)
        let mic = GeneratedInput("microphone",origin:origin), system = GeneratedInput("system",origin:origin)
        let inputs = CaptureInputLifecycle(capture:owner,originHostTime:origin,microphone:{ mic },system:{ system },failure:{ _ in })
        try await inputs.start(); try await inputs.select(me:true,others:false,atMs:100)
        let before = owner.snapshot.manifest
        mic.firstAt = 0.1
        mic.onStop = { system.failure?("Generated replacement lost during old input drain") }
        do { try await inputs.select(me:false,others:true,atMs:200); XCTFail("Lost replacement must reject the choice") } catch {}
        mic.onStop = nil
        XCTAssertTrue(owner.snapshot.me); XCTAssertFalse(owner.snapshot.others)
        XCTAssertEqual(owner.snapshot.manifest.events?.count,before.events?.count)
        XCTAssertEqual(mic.starts,2)
        try await inputs.stop(); try await owner.finish()
        let tracks = owner.snapshot.manifest.tracks.filter { $0.kind == "microphone" }
        XCTAssertEqual(tracks.count,1); XCTAssertEqual(tracks.first?.frames,1600)
    }
    @MainActor func testRejectedBrowserResumeRestartsOldMicWithoutEndingItsTrack() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let owner = try OwnedBrowserCapture(parent:root,title:"Resume rollback",microphone:true)
        let origin = AVAudioTime.hostTime(forSeconds:ProcessInfo.processInfo.systemUptime)
        let mic = GeneratedInput("microphone",origin:origin), system = GeneratedInput("system",origin:origin)
        let inputs = CaptureInputLifecycle(capture:owner,originHostTime:origin,microphone:{ mic },system:{ system },failure:{ _ in })
        try await inputs.start()
        try await inputs.select(me:true,others:false,atMs:100)
        for index in 0..<63 { try owner.browserTrack(id:"r\(index)",label:"Other",kind:"remote",sampleRate:8000,channels:1) }
        let before = owner.snapshot.manifest
        mic.firstAt = 0.1
        do { try await inputs.select(me:false,others:true,atMs:200); XCTFail("Browser resume must exceed track limit") } catch {}
        XCTAssertTrue(owner.snapshot.me); XCTAssertFalse(owner.snapshot.others)
        XCTAssertEqual(owner.snapshot.manifest.events?.count,before.events?.count)
        XCTAssertEqual(mic.starts,2); XCTAssertEqual(mic.stops,1)
        XCTAssertFalse(inputs.failedSides.contains(.me))
        try await inputs.stop(); try await owner.finish()
        let tracks = owner.snapshot.manifest.tracks.filter { $0.kind == "microphone" }
        XCTAssertEqual(tracks.count,1); XCTAssertEqual(tracks.first?.frames,1600)
    }
    @MainActor func testFailedSystemReplacementKeepsMicrophoneRunningInItsExistingTrack() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let owner = try OwnedBrowserCapture(parent:root,title:"Keep Me",microphone:true,browser:false)
        let origin = AVAudioTime.hostTime(forSeconds:ProcessInfo.processInfo.systemUptime)
        let mic = GeneratedInput("microphone",origin:origin), system = GeneratedInput("system",origin:origin)
        let inputs = CaptureInputLifecycle(capture:owner,originHostTime:origin,microphone:{ mic },system:{ system },failure:{ _ in })
        try await inputs.start()
        try await inputs.select(me:true,others:false,atMs:100)
        let before = owner.snapshot.manifest
        system.failingStart = true
        do { try await inputs.select(me:false,others:true,atMs:200); XCTFail("System input must fail") } catch {}
        XCTAssertTrue(owner.snapshot.me); XCTAssertFalse(owner.snapshot.others)
        XCTAssertEqual(owner.snapshot.manifest.events?.count,before.events?.count)
        XCTAssertEqual(mic.stops,0)
        mic.emit(at:0.1)
        try await inputs.stop(); try await owner.finish()
        let tracks = owner.snapshot.manifest.tracks.filter { $0.kind == "microphone" }
        XCTAssertEqual(tracks.count,1); XCTAssertEqual(tracks.first?.frames,1600)
    }
    @MainActor func testTrackLimitRejectsPreparedInputWithoutChangingBrowserSelection() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let owner = try OwnedBrowserCapture(parent:root,title:"Track limit",microphone:false)
        let origin = AVAudioTime.hostTime(forSeconds:ProcessInfo.processInfo.systemUptime)
        let mic = GeneratedInput("microphone",origin:origin), system = GeneratedInput("system",origin:origin)
        let inputs = CaptureInputLifecycle(capture:owner,originHostTime:origin,microphone:{ mic },system:{ system },failure:{ _ in })
        try await inputs.start()
        for index in 0..<64 { try owner.browserTrack(id:"r\(index)",label:"Other",kind:"remote",sampleRate:8000,channels:1) }
        let before = owner.snapshot.manifest
        let files = try FileManager.default.contentsOfDirectory(atPath:owner.snapshot.directory.path).sorted()
        do { try await inputs.select(me:true,others:false,atMs:100); XCTFail("Track limit must reject new microphone") } catch {}
        XCTAssertFalse(owner.snapshot.me); XCTAssertTrue(owner.snapshot.others)
        XCTAssertEqual(owner.snapshot.manifest.events?.count,before.events?.count)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath:owner.snapshot.directory.path).sorted(),files)
        XCTAssertEqual(mic.starts,1); XCTAssertEqual(mic.stops,1)
        try owner.browserAudio(id:"r0",sequence:0,offsetMs:100,pcm:Data(repeating:1,count:1600))
        try await inputs.stop(); try await owner.finish()
        XCTAssertEqual(owner.snapshot.manifest.tracks.first?.frames,800)
    }
    @MainActor func testFailedNewMicrophoneKeepsBrowserChoiceEventsAndAudioUnchanged() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let owner = try OwnedBrowserCapture(parent:root,title:"Rejected source change",microphone:false)
        let origin = AVAudioTime.hostTime(forSeconds:ProcessInfo.processInfo.systemUptime)
        let mic = GeneratedInput("microphone",origin:origin), system = GeneratedInput("system",origin:origin)
        mic.failingStart = true
        let inputs = CaptureInputLifecycle(capture:owner,originHostTime:origin,microphone:{ mic },system:{ system },failure:{ _ in })
        try await inputs.start()
        try owner.browserTrack(id:"r",label:"Other",kind:"remote",sampleRate:8000,channels:1)
        try owner.browserAudio(id:"r",sequence:0,offsetMs:0,pcm:Data(repeating:1,count:1600))
        let before = owner.snapshot.manifest
        do { try await inputs.select(me:true,others:false,atMs:100); XCTFail("Generated device start must fail") } catch {}
        XCTAssertFalse(owner.snapshot.me); XCTAssertTrue(owner.snapshot.others)
        XCTAssertEqual(owner.snapshot.manifest.events?.count,before.events?.count)
        XCTAssertEqual(owner.snapshot.manifest.tracks.count,before.tracks.count)
        try owner.browserAudio(id:"r",sequence:1,offsetMs:100,pcm:Data(repeating:2,count:1600))
        try await inputs.stop(); try await owner.finish()
        XCTAssertEqual(owner.snapshot.manifest.tracks.first?.frames,1600)
    }
    @MainActor func testTurningMeOffAfterACountedGapStillAppliesSelection() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let owner = try OwnedBrowserCapture(parent:root,title:"Turn off after gap",microphone:true)
        let origin = AVAudioTime.hostTime(forSeconds:ProcessInfo.processInfo.systemUptime)
        let mic = GeneratedInput("microphone",origin:origin), system = GeneratedInput("system",origin:origin)
        let inputs = CaptureInputLifecycle(capture:owner,originHostTime:origin,microphone:{ mic },system:{ system },failure:{ _ in })
        try await inputs.start()
        mic.emit(at:1.1)
        do { try await inputs.select(me:false,others:true,atMs:1200) }
        catch { try? await inputs.stop(); try? await owner.finish(); throw error }
        XCTAssertFalse(owner.snapshot.me); XCTAssertTrue(owner.snapshot.others)
        XCTAssertEqual(owner.snapshot.manifest.tracks.first?.gapFrames,8000)
        XCTAssertEqual(owner.snapshot.manifest.tracks.first?.ended,true)
        try await inputs.stop(); try await owner.finish()
        XCTAssertEqual(owner.snapshot.manifest.problemKind,"gap")
    }
    @MainActor func testRetryMePreservesSystemAndIgnoresFailureFromPreviousMic() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let owner = try OwnedBrowserCapture(parent:root,title:"Retry only Me",microphone:true,browser:false)
        let origin = AVAudioTime.hostTime(forSeconds:ProcessInfo.processInfo.systemUptime)
        let mic = GeneratedInput("microphone",origin:origin), system = GeneratedInput("system",origin:origin)
        let inputs = CaptureInputLifecycle(capture:owner,originHostTime:origin,microphone:{ mic },system:{ system },failure:{ _ in })
        mic.denied = true
        do { try await inputs.start(); XCTFail("Denied microphone must fail") } catch {}
        XCTAssertEqual(system.starts,1)
        mic.denied = false
        try await inputs.retry(.me)
        XCTAssertEqual(mic.starts,1); XCTAssertEqual(system.starts,1); XCTAssertEqual(system.stops,0)
        let previousFailure = mic.failure
        try await inputs.select(me:false,others:true,atMs:100)
        mic.firstAt = 0.3
        try await inputs.select(me:true,others:true,atMs:200)
        previousFailure?("Late callback from the stopped microphone")
        try await Task.sleep(for:.milliseconds(50))
        XCTAssertFalse(inputs.failedSides.contains(.me)); XCTAssertEqual(mic.stops,1)
        system.emit(at:0.1)
        try await inputs.stop(); try await owner.finish()
        XCTAssertEqual(owner.snapshot.manifest.tracks.first { $0.kind == "system" }?.frames,1600)
        XCTAssertEqual(owner.snapshot.manifest.state,"completed")
    }
    @MainActor func testLateMicFailureStopsOnlyItsInputAndRetainsSystemSamples() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let owner = try OwnedBrowserCapture(parent:root,title:"One input lost",microphone:true,browser:false)
        let origin = AVAudioTime.hostTime(forSeconds:ProcessInfo.processInfo.systemUptime)
        let mic = GeneratedInput("microphone",origin:origin), system = GeneratedInput("system",origin:origin)
        let inputs = CaptureInputLifecycle(capture:owner,originHostTime:origin,microphone:{ mic },system:{ system },failure:{ _ in })
        try await inputs.start()
        mic.failure?("Generated microphone failure")
        let deadline = Date().addingTimeInterval(3)
        while !inputs.failedSides.contains(.me) && Date() < deadline { try await Task.sleep(for:.milliseconds(5)) }
        XCTAssertTrue(inputs.failedSides.contains(.me)); XCTAssertEqual(mic.stops,1)
        XCTAssertEqual(system.stops,0)
        system.emit(at:0.1)
        try await inputs.stop(); try await owner.finish()
        XCTAssertEqual(owner.snapshot.manifest.tracks.first { $0.kind == "system" }?.frames,1600)
        XCTAssertEqual(owner.snapshot.manifest.state,"interrupted")
    }
    @MainActor func testDeniedMicrophoneDoesNotPreventSystemFallbackOrKeepRequestingPermission() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let owner = try OwnedBrowserCapture(parent:root,title:"Partial permission",microphone:true)
        let origin = AVAudioTime.hostTime(forSeconds:ProcessInfo.processInfo.systemUptime)
        let mic = GeneratedInput("microphone",origin:origin), system = GeneratedInput("system",origin:origin)
        mic.denied = true
        let inputs = CaptureInputLifecycle(capture:owner,originHostTime:origin,microphone:{ mic },system:{ system },failure:{ _ in })
        do { try await inputs.start(); XCTFail("Mic permission must fail") } catch {}
        try owner.browserLost(atMs:0)
        try await inputs.update(); try await inputs.update()
        XCTAssertEqual(mic.authorized,1); XCTAssertEqual(system.starts,1)
        XCTAssertEqual(inputs.failedSides,[.me])
        try await inputs.stop(); try await owner.finish()
        XCTAssertEqual(owner.snapshot.manifest.tracks.map(\.kind),["system"])
    }
    @MainActor func testTwoMeetingsOwnTheirNativeInputsAndOnlyTheLostOneStartsSystem() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let a = try OwnedBrowserCapture(parent:root,title:"One",microphone:true)
        let b = try OwnedBrowserCapture(parent:root,title:"Two",microphone:true)
        let origin = AVAudioTime.hostTime(forSeconds:ProcessInfo.processInfo.systemUptime)
        let micA = GeneratedInput("microphone",origin:origin), micB = GeneratedInput("microphone",origin:origin)
        let systemA = GeneratedInput("system",origin:origin), systemB = GeneratedInput("system",origin:origin)
        let first = CaptureInputLifecycle(capture:a,originHostTime:origin,microphone:{ micA },system:{ systemA },failure:{ _ in })
        let second = CaptureInputLifecycle(capture:b,originHostTime:origin,microphone:{ micB },system:{ systemB },failure:{ _ in })
        try await first.start(); try await second.start()
        try a.browserLost(atMs:0); try await first.update()
        XCTAssertEqual(systemA.starts,1); XCTAssertEqual(systemB.starts,0)
        try await first.stop(); try await a.finish()
        XCTAssertEqual(micA.stops,1); XCTAssertEqual(micB.stops,0)
        micB.emit(at:0.1)
        try await second.stop(); try await b.finish()
        XCTAssertEqual(b.snapshot.manifest.tracks.count,1)
        XCTAssertEqual(b.snapshot.manifest.tracks[0].frames,1600)
        XCTAssertEqual(a.snapshot.manifest.tracks.map(\.kind),["microphone","system"])
    }
    @MainActor func testOthersOnlyDoesNotAuthorizeMicAndLossStartsOnlySystemInItsOwnFolder() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let owner = try OwnedBrowserCapture(parent:root,title:"Only others",microphone:false)
        let origin = AVAudioTime.hostTime(forSeconds:ProcessInfo.processInfo.systemUptime)
        let mic = GeneratedInput("microphone",origin:origin), system = GeneratedInput("system",origin:origin)
        let inputs = CaptureInputLifecycle(capture:owner,originHostTime:origin,microphone:{ mic },system:{ system },failure:{ _ in })
        try await inputs.start(); XCTAssertEqual(mic.authorized,0); XCTAssertEqual(system.starts,0)
        try owner.browserLost(atMs:0)
        try await inputs.update(); try await inputs.update()
        XCTAssertEqual(mic.authorized,0); XCTAssertEqual(system.starts,1)
        try await inputs.stop(); try await owner.finish()
        XCTAssertEqual(owner.snapshot.manifest.tracks.map(\.kind),["system"])
        XCTAssertEqual(owner.snapshot.manifest.tracks[0].frames,800)
        XCTAssertEqual(owner.snapshot.manifest.events?.last(where:{ $0.type == "othersSource" })?.source,"system")
        XCTAssertEqual(owner.snapshot.manifest.events?.last?.type,"end")
    }
    @MainActor func testMeOffOnDrainsAndCreatesAFreshMicSpanWithoutStoppingBrowser() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let owner = try OwnedBrowserCapture(parent:root,title:"Me toggle",microphone:true)
        let origin = AVAudioTime.hostTime(forSeconds:ProcessInfo.processInfo.systemUptime)
        var microphones: [GeneratedInput] = []
        let system = GeneratedInput("system",origin:origin)
        let inputs = CaptureInputLifecycle(capture:owner,originHostTime:origin,microphone:{ let mic = GeneratedInput("microphone",origin:origin); mic.firstAt = Double(microphones.count)*0.3; microphones.append(mic); return mic },system:{ system },failure:{ _ in })
        try await inputs.start()
        try owner.browserTrack(id:"r",label:"Other",kind:"remote",sampleRate:8000,channels:1)
        try await inputs.select(me:false,others:true,atMs:100)
        XCTAssertEqual(microphones[0].stops,1)
        XCTAssertEqual(owner.snapshot.manifest.tracks.first { $0.kind == "microphone" }?.ended,true)
        microphones[0].emit(at:0.1) // Stopped driver has no route to a sink.
        try owner.browserAudio(id:"r",sequence:0,offsetMs:100,pcm:Data(repeating:0,count:1600))
        try await inputs.select(me:true,others:true,atMs:200)
        XCTAssertEqual(microphones.count,2); XCTAssertEqual(system.starts,0)
        try await inputs.stop(); try await owner.finish()
        let tracks = owner.snapshot.manifest.tracks.filter { $0.kind == "microphone" }
        XCTAssertEqual(tracks.count,2); XCTAssertNotEqual(tracks[0].id,tracks[1].id)
        XCTAssertEqual(tracks.map(\.frames),[800,800])
        XCTAssertEqual(owner.snapshot.manifest.tracks.first { $0.kind == "remote" }?.frames,800)
    }
    @MainActor func testDeniedMeSelectionLeavesTheWorkingSelectionAndBrowserUntouched() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let owner = try OwnedBrowserCapture(parent:root,title:"Denied mic",microphone:false)
        let origin = AVAudioTime.hostTime(forSeconds:ProcessInfo.processInfo.systemUptime)
        let mic = GeneratedInput("microphone",origin:origin), system = GeneratedInput("system",origin:origin)
        mic.denied = true
        let inputs = CaptureInputLifecycle(capture:owner,originHostTime:origin,microphone:{ mic },system:{ system },failure:{ _ in })
        do { try await inputs.select(me:true,others:false,atMs:0); XCTFail("Denied permission must fail") } catch {}
        XCTAssertFalse(owner.snapshot.me); XCTAssertTrue(owner.snapshot.others); XCTAssertTrue(owner.snapshot.browserAlive)
        XCTAssertEqual(owner.snapshot.manifest.events?.count,2); XCTAssertEqual(mic.starts,0)
        try await inputs.stop(); try await owner.finish()
    }
    @MainActor func testStopDuringPermissionWaitPreventsALateMicrophoneStart() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let owner = try OwnedBrowserCapture(parent:root,title:"Pending permission",microphone:true,browser:false)
        let origin = AVAudioTime.hostTime(forSeconds:ProcessInfo.processInfo.systemUptime)
        let mic = GeneratedInput("microphone",origin:origin), system = GeneratedInput("system",origin:origin)
        mic.holdPermission = true
        let inputs = CaptureInputLifecycle(capture:owner,originHostTime:origin,microphone:{ mic },system:{ system },failure:{ _ in })
        let starting = Task { try await inputs.start() }
        let deadline = Date().addingTimeInterval(2)
        while mic.permission == nil && Date() < deadline { await Task.yield() }
        guard mic.permission != nil else { XCTFail("Permission request did not start"); throw BrowserIPCError.timeout }
        let systemStartedBeforeReply = system.starts
        var stopped = false
        let stopping = Task { try await inputs.stop(); stopped = true }
        let stopDeadline = Date().addingTimeInterval(2)
        while !stopped && Date() < stopDeadline { try await Task.sleep(for:.milliseconds(5)) }
        let stoppedBeforeReply = stopped
        mic.permission?.resume(); mic.permission = nil
        try await starting.value; try await stopping.value; try await owner.finish()
        XCTAssertTrue(stoppedBeforeReply,"Stop must not require an answer to the permission prompt")
        XCTAssertEqual(systemStartedBeforeReply,1,"Available Others must not wait for microphone permission")
        XCTAssertEqual(mic.starts,0); XCTAssertEqual(system.stops,1)
        XCTAssertEqual(owner.snapshot.manifest.tracks.map(\.kind),["system"])
    }
}
