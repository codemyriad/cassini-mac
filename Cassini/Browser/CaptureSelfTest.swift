// SPDX-License-Identifier: GPL-3.0-or-later
#if DEBUG
import AppKit
import CassiniKit
import CassiniRecording
import CassiniLibrary

/// Native framing through the actual bundled executables; no capture APIs or
/// browser profiles are involved. All blocking pipe operations leave UI actor.
final class CaptureProbeProcess: @unchecked Sendable {
    private let process = Process(), input = Pipe(), output = Pipe(), errors = Pipe()
    private let queue = DispatchQueue(label:"com.codemyriad.cassini.capture-probe." + UUID().uuidString)
    init(_ name: String, root: URL) throws {
        process.executableURL = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/" + name)
        process.environment = ["CASSINI_CONTROL_PIPE_ROOT":root.path]
        process.standardInput = input; process.standardOutput = output; process.standardError = errors
        try process.run()
    }
    func send(_ json: [String:Any]) async throws {
        let data = try JSONSerialization.data(withJSONObject:json)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void,Error>) in
            queue.async { continuation.resume(with:Result { try NativeMessageFraming.write(data,to:self.input.fileHandleForWriting) }) }
        }
    }
    func read() async throws -> JSON {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with:Result {
                guard let data = try NativeMessageFraming.read(from:self.output.fileHandleForReading) else { throw CocoaError(.fileReadCorruptFile) }
                return try JSONParser.parse(data)
            }) }
        }
    }
    func request(_ json: [String:Any]) async throws -> JSON { try await send(json); return try await read() }
    func end() async {
        await withCheckedContinuation { continuation in
            queue.async {
                try? self.input.fileHandleForWriting.close()
                let deadline = Date().addingTimeInterval(2)
                while self.process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval:0.01) }
                if self.process.isRunning { self.process.terminate() }
                self.process.waitUntilExit()
                continuation.resume()
            }
        }
    }
}
@MainActor final class CaptureProbeProfile {
    let root: URL, title: String
    var control: CaptureProbeProcess
    var audio: CaptureProbeProcess?
    var captureID: String?, path: String?
    var sequence = 0
    var nextStartFails = false
    init(root: URL, title: String) throws {
        self.root = root; self.title = title
        control = try CaptureProbeProcess("cassini-control-host",root:root)
    }
    func ready(active: Bool = true, interrupted: Bool = false) async throws {
        try await control.send(["type":"hello","version":1,"capabilities":["independent-sessions-v1"]])
        try await control.send(status(interrupted:interrupted))
        try await meetings(active)
    }
    func meetings(_ active: Bool) async throws {
        try await control.send(["type":"meetings","meetings":active || audio != nil ? [["tabId":2,"title":title,"url":"https://meeting.example/2","sourceCount":active ? 1 : 0]] : []])
    }
    func status(interrupted: Bool = false) -> [String:Any] {
        var packet: [String:Any] = ["type":"status","recording":audio != nil,"tabId":audio == nil ? NSNull() : 2,"path":path as Any? ?? NSNull(),"message":"Fixture status"]
        let entry: [String:Any] = ["recording":audio != nil,"tabId":2,"path":path as Any? ?? NSNull(),"captureId":captureID as Any? ?? NSNull(),"message":"Fixture status","tracks":1,"stopping":false]
        packet["sessions"] = audio == nil ? [] : [entry]
        if interrupted { packet["interrupted"] = [entry] }
        return packet
    }
    func performNext() async throws -> JSON {
        let command = try await control.read()
        guard let request = command["requestId"]?.string, let action = command["action"]?.string else { throw CocoaError(.fileReadCorruptFile) }
        if action == "start", nextStartFails {
            nextStartFails = false
            try await control.send(["type":"result","requestId":request,"ok":false,"error":"Generated start failure","status":status()])
            try await control.send(status())
            return command
        }
        if action == "start" {
            let token = UUID().uuidString.lowercased(), audio = try CaptureProbeProcess("cassini-browser-host",root:root)
            self.audio = audio; captureID = token; sequence = 0
            let started = try await audio.request(["type":"start","version":1,"independent":true,"captureId":token,"timelineOriginMs":Int(Date().timeIntervalSince1970*1000),"microphone":command["microphone"]?.bool ?? true,"title":title])
            guard started["type"]?.string == "started" else { throw CocoaError(.fileWriteUnknown) }
            path = started["path"]?.string
            _ = try await audio.request(["type":"track","id":"remote","label":"Generated remote","kind":"remote","sampleRate":8000,"channels":1])
            try await emit()
        } else {
            if let audio { _ = try await audio.request(["type":"stop"]); await audio.end(); self.audio = nil }
        }
        let snapshot = status()
        try await control.send(["type":"result","requestId":request,"ok":true,"status":snapshot])
        try await control.send(snapshot)
        return command
    }
    func emit() async throws {
        guard let audio else { throw CocoaError(.fileReadUnknown) }
        let answer = try await audio.request(["type":"audio","id":"remote","sequence":sequence,"offsetMs":sequence*100,"pcm":Data(repeating:0x12,count:1600).base64EncodedString()])
        guard answer["type"]?.string == "ack" else { throw CocoaError(.fileWriteUnknown) }
        sequence += 1
    }
    func loseBrowser() async throws {
        guard let audio else { throw CocoaError(.fileReadUnknown) }
        _ = try await audio.request(["type":"stop","failureReason":"lost"])
        await audio.end(); self.audio = nil
    }
    func reconnectInterrupted() async throws {
        await control.end()
        control = try CaptureProbeProcess("cassini-control-host",root:root)
        try await ready(interrupted:true)
    }
    func finish() async { if let audio { await audio.end(); self.audio = nil }; await control.end() }
}
@MainActor enum CaptureSelfTest {
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw NSError(domain:"CaptureSelfTest",code:1,userInfo:[NSLocalizedDescriptionKey:message]) }
    }
    static func wait(_ condition: @escaping @MainActor () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 8
        while !condition() && ProcessInfo.processInfo.systemUptime < deadline { try await Task.sleep(for:.milliseconds(25)) }
        try require(condition(),"Private capture state did not settle")
    }
    static func run() async {
        guard CaptureFixture.enabled, let root = RecordingFixture.root else { NSApp.terminate(nil); return }
        let collection = CaptureCollection.shared
        var profiles: [CaptureProbeProfile] = []
        var report: [String:Any] = [:]
        var stage = "start protected service"
        do {
            try await Task.detached {
                try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
            }.value
            LibraryStore.shared.start()
            let pipe = root.appendingPathComponent(".control")
            await collection.start(root:pipe)
            try require(collection.available,"Protected service started")
            let one = try CaptureProbeProfile(root:pipe,title:"Generated profile one"), two = try CaptureProbeProfile(root:pipe,title:"Generated profile two")
            profiles = [one,two]
            try await one.ready(); try await two.ready()
            try await wait { collection.peers.filter(\.reconciled).count == 2 && collection.hasCalls }
            stage = "start two profiles"
            try await collection.record()
            _ = try await one.performNext(); _ = try await two.performNext()
            try await wait { collection.captures.count == 2 && collection.captures.values.allSatisfy { $0.key != nil && $0.snapshot.manifest.tracks.contains { $0.kind == "microphone" && $0.frames > 0 } } }
            try await one.emit(); try await two.emit()
            try await wait { LibraryStore.shared.meetings.filter { $0.state.lifecycle == .recording }.count == 2 }
            let first = try collection.captures.values.first { $0.snapshot.manifest.title == one.title }.unwrap()
            let second = try collection.captures.values.first { $0.snapshot.manifest.title == two.title }.unwrap()
            try require(first.snapshot.directory != second.snapshot.directory,"Profiles have distinct owned folders")
            report["twoProfilesSameTabIndependent"] = true
            stage = "change per-meeting sources"
            try await collection.select(first.snapshot.manifest.id,me:false,others:true)
            let micEnd = collection.captures[first.snapshot.manifest.id]!.snapshot.manifest.tracks.filter { $0.kind == "microphone" }.reduce(UInt64(0)) { $0 + $1.frames }
            try await one.emit(); try await Task.sleep(for:.milliseconds(100))
            try require(collection.captures[first.snapshot.manifest.id]!.snapshot.manifest.tracks.filter { $0.kind == "microphone" }.reduce(UInt64(0)) { $0 + $1.frames } == micEnd,"Me off stops native admission")
            stage = "reject unavailable replacement input"
            let beforeChoice = first.owner.snapshot.manifest
            CaptureFixture.microphoneStartsAllowed = false
            var rejectedChoice = false
            do { try await collection.select(first.snapshot.manifest.id,me:true,others:false) }
            catch { rejectedChoice = true }
            CaptureFixture.microphoneStartsAllowed = true
            try require(rejectedChoice && !first.owner.snapshot.me && first.owner.snapshot.others,"Failed microphone keeps Others selected")
            try require(first.owner.snapshot.manifest.events?.count == beforeChoice.events?.count && first.owner.snapshot.manifest.tracks.count == beforeChoice.tracks.count,"Rejected selection publishes no events or tracks")
            let remoteTrack = try first.owner.snapshot.manifest.tracks.first { $0.kind == "remote" }.unwrap()
            let remoteURL = first.owner.snapshot.directory.appendingPathComponent(remoteTrack.file)
            let browserBefore = try FileManager.default.attributesOfItem(atPath:remoteURL.path)[.size] as? UInt64 ?? 0
            try await one.emit()
            let browserAfter = try FileManager.default.attributesOfItem(atPath:remoteURL.path)[.size] as? UInt64 ?? 0
            try require(browserAfter > browserBefore,"Browser audio continues after rejected input")
            report["failedSourceChangeKeepsSelectionAndAudio"] = true
            stage = "accept replacement input"
            try await collection.select(first.snapshot.manifest.id,me:true,others:false)
            try await one.emit()
            try await collection.select(first.snapshot.manifest.id,me:true,others:true)
            try await one.emit()
            report["realSelectionUsesOwnedInputLifecycle"] = true
            stage = "stop only first meeting"
            collection.stop(first.snapshot.manifest.id)
            try await wait { first.owner.snapshot.manifest.tracks.filter { $0.kind == "microphone" }.allSatisfy { $0.ended == true } }
            let stoppedMicFrames = first.owner.snapshot.manifest.tracks.filter { $0.kind == "microphone" }.reduce(UInt64(0)) { $0 + $1.frames }
            try await Task.sleep(for:.milliseconds(100))
            try require(first.owner.snapshot.phase == .recording,"Browser tail remains pending in the fixture")
            try require(first.owner.snapshot.manifest.tracks.filter { $0.kind == "microphone" }.reduce(UInt64(0)) { $0 + $1.frames } == stoppedMicFrames,"Native microphone stops before the browser flush")
            report["nativeStopsBeforeBrowserFlush"] = true
            _ = try await one.performNext()
            try await wait { collection.captures[first.snapshot.manifest.id] == nil && collection.captures[second.snapshot.manifest.id] != nil }
            try await two.emit()
            report["pageStopLeavesOtherMeetingRecording"] = true
            var automatic: [UUID] = [], fallbacks: [UUID] = []
            collection.onAutomaticStart = { automatic.append($0) }; collection.onFallback = { fallbacks.append($0) }
            try await collection.setAutoRecord(true)
            stage = "browser loss and system fallback"
            try await two.loseBrowser()
            try await wait { collection.captures[second.snapshot.manifest.id]?.snapshot.manifest.tracks.contains { $0.kind == "system" && $0.frames > 0 } == true }
            try require(collection.captures[second.snapshot.manifest.id]?.snapshot.directory == second.snapshot.directory,"Fallback retains the folder")
            stage = "reconcile worker recovery"
            try await two.reconnectInterrupted()
            try await wait {
                guard let key = collection.captures[second.snapshot.manifest.id]?.key else { return false }
                return key.peer != second.key?.peer && collection.peers.filter(\.reconciled).count == 2
            }
            try await Task.sleep(for:.milliseconds(200))
            try require(collection.captures.count == 1 && automatic.isEmpty,"Recovery does not auto-restore browser capture")
            try require(fallbacks == [second.snapshot.manifest.id],"Actual system fallback is announced exactly once")
            report["fallbackAndWorkerRecoveryKeepOneFolder"] = true
            collection.stop(second.snapshot.manifest.id)
            _ = try await two.performNext()
            await collection.stopAndWait()
            try await wait { collection.captures.isEmpty }
            stage = "auto-start new call and notification Stop"
            try await one.meetings(false); try await two.meetings(false)
            try await Task.sleep(for:.milliseconds(100))
            try await one.meetings(true)
            _ = try await one.performNext()
            try await wait { collection.captures.count == 1 && automatic.count == 1 }
            let automaticID = try collection.captures.keys.first.unwrap()
            CaptureNotifications.handle(action:"stop",id:automaticID)
            _ = try await one.performNext()
            await collection.stopAndWait()
            try await wait { collection.captures.isEmpty }
            report["newCallAutoStartAndNotificationStop"] = true
            try await collection.setAutoRecord(false)
            try await one.meetings(false); try await two.meetings(false)
            try await wait { !collection.hasCalls }
            stage = "partial failure and targeted retry"
            one.nextStartFails = true
            try await one.meetings(true); try await two.meetings(true)
            try await wait { collection.peers.flatMap(\.meetings).filter { $0.sourceCount > 0 }.count == 2 }
            try await collection.record()
            _ = try await one.performNext(); _ = try await two.performNext()
            try await wait { collection.failedMeetings.count == 1 && collection.captures.count == 1 && !collection.starting }
            try require(!collection.recordFailed,"One failed meeting must not become an all-failed message")
            let successfulToken = two.captureID, retryKey = try collection.failedMeetings.keys.first.unwrap()
            collection.retry(retryKey)
            _ = try await one.performNext()
            try await wait { collection.captures.count == 2 && collection.failedMeetings.isEmpty }
            try require(two.captureID == successfulToken,"Retry must not restart the successful meeting")
            stage = "hang up while the tab stays open"
            try await one.meetings(false)
            let ended = try await one.performNext()
            try require(ended["action"]?.string == "stop","Call end requests Stop instead of fallback")
            try await wait { collection.captures.count == 1 }
            try await two.emit()
            try require(two.captureID == successfulToken,"Call end leaves the other meeting recording")
            report["hangupStopsOnlyEndedMeeting"] = true
            collection.stopAll()
            _ = try await two.performNext()
            await collection.stopAndWait()
            try await wait { collection.captures.isEmpty }
            report["partialFailureRetriesOnlyThatMeeting"] = true
            try await one.meetings(false); try await two.meetings(false)
            try await wait { !collection.hasCalls }
            stage = "expire fallback whose browser never returns"
            try await one.meetings(true)
            try await wait { collection.hasCalls }
            try await collection.record(); _ = try await one.performNext()
            try await wait { collection.captures.count == 1 && collection.captures.values.first?.key != nil }
            let expiring = try collection.captures.values.first.unwrap()
            try await one.loseBrowser()
            try await wait { expiring.owner.snapshot.browserLostUptime != nil && expiring.owner.snapshot.manifest.tracks.contains { $0.kind == "system" && $0.frames > 0 } }
            let lostAt = try expiring.owner.snapshot.browserLostUptime.unwrap()
            await one.control.end()
            try await wait { !collection.peers.contains { $0.id == expiring.key?.peer } }
            collection.pollLifetimeForTesting(at:lostAt + 30.01)
            try await wait { collection.captures.isEmpty }
            report["unobservedFallbackExpires"] = true
            stage = "denied microphone and disk reserve"
            CaptureFixture.microphoneAllowed = false
            let beforeMicStarts = CaptureFixture.microphoneStarts
            try await collection.record()
            try await wait { collection.captures.values.contains { $0.snapshot.manifest.source == "macos" && $0.snapshot.manifest.tracks.contains { $0.kind == "system" && $0.frames > 0 } } }
            try require(CaptureFixture.microphoneStarts == beforeMicStarts,"Denied microphone did not start a device driver")
            try require(collection.first?.input.failedSides.contains(.me) == true,"Permission warning remains distinct from selection")
            try require(fallbacks == [second.snapshot.manifest.id],"A normal native start must not announce browser fallback")
            report["nativeStartDoesNotReportFallback"] = true
            collection.applyDiskBudgetForTesting(DiskBudget(total:100<<30,free:0,bytesPerSecond:16000))
            await collection.stopAndWait()
            report["deniedMicKeepsOthersRecording"] = true
            try require(collection.diskStopped,"Reserve Stop keeps its reason after saving")
            report["diskReserveStopsAndKeeps"] = true
            try await wait { collection.captures.isEmpty }
            let before = try folders(root)
            stage = "nothing started leaves no folder"
            CaptureFixture.systemAllowed = false
            try await collection.record()
            try await wait { collection.recordFailed && collection.captures.isEmpty }
            let after = try folders(root)
            try require(after == before,"No samples means no new Library folder")
            report["nothingStartedLeavesNoLibraryEntry"] = true
            stage = "shutdown"
            for profile in profiles { await profile.finish() }
            profiles = []
            await collection.shutdown()
            LibraryStore.shared.stop()
            report["audioDevicesOpened"] = false; report["browserProfilesTouched"] = false
            report["nativeMessagingProcesses"] = true; report["exactProductProfile"] = true
            try FileHandle.standardOutput.write(contentsOf:JSONSerialization.data(withJSONObject:report,options:.sortedKeys))
            try FileManager.default.removeItem(at:root)
        } catch {
            for profile in profiles { await profile.finish() }
            await collection.shutdown()
            try? FileHandle.standardError.write(contentsOf:Data(("CaptureSelfTest [" + stage + "]: " + String(describing:error) + "\n").utf8))
            exit(1)
        }
        NSApp.terminate(nil)
    }
    private static func folders(_ root: URL) throws -> [String] { try FileManager.default.contentsOfDirectory(atPath:root.path).filter { $0.hasPrefix("Recording-") }.sorted() }
}
private extension Optional {
    func unwrap() throws -> Wrapped { guard let self else { throw CocoaError(.fileReadCorruptFile) }; return self }
}
#endif
