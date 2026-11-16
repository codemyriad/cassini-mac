// SPDX-License-Identifier: GPL-3.0-or-later
#if DEBUG
import AppKit
import AVFoundation
import CassiniRecording
import CassiniBrowserControl

@MainActor enum TestRecordingSelfTest {
    enum Failure: Error { case check(String) }
    static func check(_ value: Bool, _ text: String) throws { if !value { throw Failure.check(text) } }
    static func run() async {
        guard ProcessInfo.processInfo.environment["CASSINI_LOCAL_WORKFLOW_TESTS"] == "1" || ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] == "true" else { exit(78) }
        do {
            let test = TestRecordingController.shared
            test.playAutomatically = false
            let mic = TestInput(id:"microphone",kind:"microphone")
            let system = TestInput(id:"output",kind:"system")
            test.makeMicrophone = { mic }; test.makeSystem = { system }
            let (duration, finish) = AsyncStream<Void>.makeStream()
            test.duration = { var iterator = duration.makeAsyncIterator(); _ = await iterator.next(); try Task.checkCancellation() }
            await withCheckedContinuation { continuation in
                test.changed = { if test.phase == .recording { test.changed = nil; continuation.resume() } }
                test.start()
            }
            let folder = test.fixtureDirectory!
            try check(folder.path.hasPrefix(TestRecordingController.root.path + "/"),"test has a private destination")
            await withCheckedContinuation { continuation in
                test.changed = { if test.phase == .result { test.changed = nil; continuation.resume() } }
                finish.yield(); finish.finish()
            }
            try check(test.problem == nil,"generated capture finishes: \(test.problem ?? "")")
            try check(test.heard == [.me,.others],"both native PCM streams heard")
            try check(mic.stops == 1 && system.stops == 1,"each native input stops once")
            let tracks = try await Task.detached {
                let bytes = try Data(contentsOf:folder.appendingPathComponent("session.json"))
                return (try JSONSerialization.jsonObject(with:bytes) as! [String:Any])["tracks"] as! [[String:Any]]
            }.value
            try check(Set(tracks.compactMap { $0["kind"] as? String }) == ["microphone","system"],"both native tracks retained for playback")
            await test.cancel().value
            let exists = await Task.detached { FileManager.default.fileExists(atPath:folder.path) }.value
            try check(!exists,"closing removes every test file")

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
            FileHandle.standardOutput.write(Data("{\"nativeTestStreams\":true,\"temporaryCleanup\":true,\"latePermissionCancelled\":true,\"updatesLast\":true}\n".utf8))
            exit(0)
        } catch { FileHandle.standardError.write(Data("\(error)\n".utf8)); exit(1) }
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
