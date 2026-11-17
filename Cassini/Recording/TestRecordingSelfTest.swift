// SPDX-License-Identifier: GPL-3.0-or-later
#if DEBUG
import AppKit
import AVFoundation
import CassiniRecording
import CassiniBrowserControl
import Observation

@MainActor enum TestRecordingSelfTest {
    enum Failure: Error { case check(String) }
    static func check(_ value: Bool, _ text: String) throws { if !value { throw Failure.check(text) } }
    static func run() async {
        guard ProcessInfo.processInfo.environment["CASSINI_LOCAL_WORKFLOW_TESTS"] == "1" || ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] == "true" else { exit(78) }
        do {
            let test = TestRecordingController.shared
            test.playAutomatically = false
            let mic = Device(), system = Device()
            test.makeMicrophone = { TestRecordingInput(.me,open:mic.open) }
            test.makeSystem = { TestRecordingInput(.others,open:system.open) }
            let (duration, finish) = AsyncStream<Void>.makeStream()
            test.duration = { var iterator = duration.makeAsyncIterator(); _ = await iterator.next(); try Task.checkCancellation() }
            await withCheckedContinuation { continuation in
                test.changed = { if test.phase == .recording { test.changed = nil; continuation.resume() } }
                test.start()
            }
            let folder = test.fixtureDirectory!
            try check(folder.path.hasPrefix(TestRecordingController.root.path + "/"),"test has a private destination")
            await observe { test.heard == [.me,.others] }
            await withCheckedContinuation { continuation in
                test.changed = { if test.phase == .result { test.changed = nil; continuation.resume() } }
                finish.yield(); finish.finish()
            }
            try check(test.problem == nil,"generated capture finishes: \(test.problem ?? "")")
            try check(test.heard == [.me,.others],"both native PCM streams heard")
            try check(mic.closedOnce && system.closedOnce,"each queued device closes once off the main actor")
            let tracks = try await Task.detached {
                let bytes = try Data(contentsOf:folder.appendingPathComponent("session.json"))
                return (try JSONSerialization.jsonObject(with:bytes) as! [String:Any])["tracks"] as! [[String:Any]]
            }.value
            try check(tracks.count == 2 && Set(tracks.compactMap { $0["kind"] as? String }) == ["microphone","system"],"one native track per side retained for playback")
            await test.cancel().value
            let exists = await Task.detached { FileManager.default.fileExists(atPath:folder.path) }.value
            try check(!exists,"closing removes every test file")
            try await queuedOpenCancellation()
            try await queuedOpenRefusal(test)
            try await captureAdmissionAfterCleanup(test)

            // Cancelling while the OS permission answer is pending must drain
            // ownership now and ignore a subsequent permission grant.
            let waiting = TestInput(id:"microphone",kind:"microphone")
            let (permission, grant) = AsyncStream<Void>.makeStream()
            waiting.permission = permission
            test.makeMicrophone = { waiting }; test.makeSystem = { TestInput(id:"output",kind:"system") }
            await withCheckedContinuation { continuation in
                waiting.authorizing = { waiting.authorizing = nil; continuation.resume() }
                test.start()
            }
            let cancelledFolder = test.fixtureDirectory!
            await test.cancel().value
            await withCheckedContinuation { continuation in
                waiting.authorized = { continuation.resume() }
                grant.yield(); grant.finish()
            }
            try check(waiting.starts == 0,"late permission cannot start a cancelled test")
            let cancelledExists = await Task.detached { FileManager.default.fileExists(atPath:cancelledFolder.path) }.value
            try check(!cancelledExists,"pending authorization cleanup removes its directory")
            try check(SettingsTab.allCases.map(\.rawValue) == ["recording","transcription","library","browser","updates"],"Updates is last")
            FileHandle.standardOutput.write(Data("{\"nativeTestStreams\":true,\"temporaryCleanup\":true,\"latePermissionCancelled\":true,\"queuedInputLateOpen\":true,\"queuedInputOpenRefusal\":true,\"captureAdmissionAfterCleanup\":true,\"updatesLast\":true}\n".utf8))
            exit(0)
        } catch { FileHandle.standardError.write(Data("\(error)\n".utf8)); exit(1) }
    }
    private static func observe(_ ready: @escaping @MainActor () -> Bool) async {
        while !ready() {
            let (events, signal) = AsyncStream<Void>.makeStream()
            withObservationTracking { _ = ready() } onChange: { signal.yield(); signal.finish() }
            var iterator = events.makeAsyncIterator(); _ = await iterator.next()
        }
    }
    private static func queuedOpenCancellation() async throws {
        for side in [CaptureSide.me,.others] {
            let root = TestRecordingController.root
            let session = try await Task.detached { try RecordingSession(parent:root,title:"Queued input probe",source:"macos") }.value
            let device = Device(held:true)
            let driver = TestRecordingInput(side,open:device.open)
            let sink = RecordingSink(session:session,originHostTime:mach_absolute_time(),onFailure:{ _ in device.reportFailure() })
            try driver.start(sink:sink,failure:{ _ in device.reportFailure() })
            var opened = device.opening.makeAsyncIterator(); _ = await opened.next()
            driver.stop()
            device.release()
            await driver.drain()
            // A callback already retained by Core Audio must also be harmless
            // after stop/drain, even if it arrives after the device was closed.
            device.emit(); device.reportLateFailure()
            let empty = try await Task.detached {
                try sink.finish(problem:nil)
                return session.manifest.tracks.allSatisfy { $0.frames == 0 }
            }.value
            try check(device.closedOnce && device.failures == 0 && empty,"late open closes once and admits neither buffers nor errors after Stop")
            let folder = session.directory
            try await Task.detached { try FileManager.default.removeItem(at:folder) }.value
        }
    }
    private static func queuedOpenRefusal(_ test: TestRecordingController) async throws {
        let mic = Device(fails:true), system = Device(fails:true)
        test.makeMicrophone = { TestRecordingInput(.me,open:mic.open) }
        test.makeSystem = { TestRecordingInput(.others,open:system.open) }
        let (duration, finish) = AsyncStream<Void>.makeStream()
        test.duration = { var iterator = duration.makeAsyncIterator(); _ = await iterator.next() }
        test.start()
        await observe { test.refused.count == 2 && test.phase == .recording }
        finish.yield(); finish.finish()
        await observe { test.phase == .result }
        try check(test.refused == [.me:CaptureRefusal.deviceUnavailable,.others:CaptureRefusal.deviceUnavailable],"queued open errors are deviceUnavailable refusals")
        try check(test.problem == nil && test.heard.isEmpty,"open errors before first PCM do not fail the recording")
        await test.cancel().value
    }
    private static func captureAdmissionAfterCleanup(_ test: TestRecordingController) async throws {
        test.makeMicrophone = { TestInput(id:"microphone",kind:"microphone") }
        test.makeSystem = { TestInput(id:"output",kind:"system") }
        let (held, release) = AsyncStream<Void>.makeStream()
        let heldWork = Task { var iterator = held.makeAsyncIterator(); _ = await iterator.next() }
        let (entered, signalEntered) = AsyncStream<Void>.makeStream()
        test.duration = { signalEntered.yield(); signalEntered.finish(); await heldWork.value }
        test.start()
        var durationEntered = entered.makeAsyncIterator(); _ = await durationEntered.next()
        let root = TestRecordingController.root
        let owner = try await Task.detached {
            try OwnedBrowserCapture(parent:root,title:"Capture during test cleanup",microphone:false,browser:true,managedBrowser:true)
        }.value
        let (cancelled, signalCancelled) = AsyncStream<Void>.makeStream()
        test.changed = {
            if test.phase == .idle { test.changed = nil; signalCancelled.yield(); signalCancelled.finish() }
        }
        let collection = CaptureCollection.shared
        let admission = Task { await collection.admitAfterTestCleanupForTesting(owner) }
        var cleanupEntered = cancelled.makeAsyncIterator(); _ = await cleanupEntered.next()
        try await owner.finish()
        release.yield(); release.finish()
        await admission.value
        try check(collection.captures[owner.snapshot.manifest.id] == nil,"a call ending during test cleanup cannot register a stale recording")
        let folder = owner.snapshot.directory
        try await Task.detached { try FileManager.default.removeItem(at:folder) }.value
        await test.cancel().value
    }
    /// Only the hardware operation is replaced. The real driver's queue,
    /// cancellation admission and close/drain ordering execute in every case.
    private final class Device: TestRecordingDevice, @unchecked Sendable {
        let opening: AsyncStream<Void>
        private let began: AsyncStream<Void>.Continuation
        private let gate: DispatchSemaphore?
        private let fails: Bool
        private let lock = NSLock()
        private var callbacks: TestRecordingInput.Callbacks?
        private var active = false, offMain = true
        private var closes = 0, failureCount = 0
        init(held: Bool = false, fails: Bool = false) {
            (opening,began) = AsyncStream<Void>.makeStream()
            gate = held ? DispatchSemaphore(value:0):nil; self.fails = fails
        }
        var closedOnce: Bool { lock.withLock { !active && closes == 1 && offMain } }
        var failures: Int { lock.withLock { failureCount } }
        func open(_ side: CaptureSide, _ callbacks: TestRecordingInput.Callbacks) throws -> any TestRecordingDevice {
            lock.withLock { self.callbacks = callbacks; offMain = offMain && !Thread.isMainThread }
            began.yield(); began.finish()
            gate?.wait() // Event gate on the driver's worker, never the main actor.
            if fails { throw CocoaError(.fileReadUnknown) }
            lock.withLock { active = true }
            emit()
            return self
        }
        func release() { gate?.signal() }
        func close() { lock.withLock { active = false; closes += 1; offMain = offMain && !Thread.isMainThread } }
        func reportFailure() { lock.withLock { failureCount += 1 } }
        func reportLateFailure() { lock.withLock { callbacks }?.failure("late device event") }
        func emit() {
            let format = AVAudioFormat(standardFormatWithSampleRate:48000,channels:1)!
            let buffer = AVAudioPCMBuffer(pcmFormat:format,frameCapacity:9600)!
            buffer.frameLength = 9600
            for n in 0..<9600 { buffer.floatChannelData![0][n] = 0.3 * sin(Float(n) * 0.1) }
            lock.withLock { callbacks }?.receive(buffer,mach_absolute_time())
        }
    }
    private final class TestInput: CaptureInput {
        let id: String, kind: String
        var starts = 0, stops = 0
        var permission: AsyncStream<Void>?
        var authorizing: (() -> Void)?, authorized: (() -> Void)?
        init(id: String, kind: String) { self.id = id; self.kind = kind }
        func authorize() async throws {
            if let permission {
                authorizing?(); var iterator = permission.makeAsyncIterator(); _ = await iterator.next(); authorized?()
            }
        }
        func start(sink: RecordingSink, failure: @escaping @Sendable (String) -> Void) throws {
            starts += 1
            let format = AVAudioFormat(standardFormatWithSampleRate:48000,channels:1)!
            let buffer = AVAudioPCMBuffer(pcmFormat:format,frameCapacity:9600)!
            buffer.frameLength = 9600
            for n in 0..<9600 { buffer.floatChannelData![0][n] = 0.3 * sin(Float(n) * 0.1) }
            sink.receive(buffer,hostTime:mach_absolute_time(),id:id,label:id,kind:kind)
        }
        func stop() { stops += 1 }
    }
}
#endif
