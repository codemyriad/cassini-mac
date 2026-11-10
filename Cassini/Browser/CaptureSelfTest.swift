// SPDX-License-Identifier: GPL-3.0-or-later
#if DEBUG
import AppKit
import Observation
import CassiniKit
import CassiniRecording
import CassiniLibrary
import Darwin

/// Native framing through the actual bundled executables; no capture APIs or
/// browser profiles are involved. All blocking pipe operations leave UI actor.
final class CaptureProbeProcess: @unchecked Sendable {
    private let process = Process(), input = Pipe(), output = Pipe(), errors = Pipe()
    private let queue = DispatchQueue(label:"io.codemyriad.cassini.capture-probe." + UUID().uuidString)
    private let exited = DispatchGroup()
    private let lifecycle = NSLock()
    private var ending = false
    init(_ name: String, root: URL) throws {
        process.executableURL = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/" + name)
        process.environment = ["CASSINI_CONTROL_PIPE_ROOT":root.path]
        process.standardInput = input; process.standardOutput = output; process.standardError = errors
        let fd = output.fileHandleForReading.fileDescriptor, flags = fcntl(output.fileHandleForReading.fileDescriptor,F_GETFL)
        guard flags >= 0,fcntl(fd,F_SETFL,flags | O_NONBLOCK) == 0 else { throw POSIXError(.EIO) }
        let exited = self.exited
        exited.enter()
        process.terminationHandler = { _ in exited.leave() }
        do {
            try process.run()
        } catch {
            exited.leave()
            throw error
        }
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
                let deadline = DispatchTime.now().uptimeNanoseconds + 8_000_000_000
                let header = try self.exact(4,deadline:deadline)
                let count = header.withUnsafeBytes { UInt32(littleEndian:$0.loadUnaligned(as:UInt32.self)) }
                guard count > 0,count <= NativeMessageFraming.maximumBytes else { throw CocoaError(.fileReadCorruptFile) }
                let data = try self.exact(Int(count),deadline:deadline)
                return try JSONParser.parse(data)
            }) }
        }
    }
    private func exact(_ count: Int, deadline: UInt64) throws -> Data {
        var data = Data(), bytes = [UInt8](repeating:0,count:min(count,8192))
        let fd = output.fileHandleForReading.fileDescriptor
        while data.count < count {
            guard !lifecycle.withLock({ ending }) else { throw CocoaError(.userCancelled) }
            guard DispatchTime.now().uptimeNanoseconds < deadline else {
                throw BrowserProtocolError("fixture-timeout","Timed out reading " + (process.executableURL?.lastPathComponent ?? "private child"))
            }
            let size = Darwin.read(fd,&bytes,min(bytes.count,count-data.count))
            if size > 0 { data.append(contentsOf:bytes.prefix(size)); continue }
            if size < 0,errno == EINTR { continue }
            if size < 0,errno == EAGAIN {
                var item = pollfd(fd:fd,events:Int16(POLLIN),revents:0)
                let result = poll(&item,1,100)
                guard result >= 0 || errno == EINTR else { throw POSIXError(.EIO) }
                continue
            }
            throw CocoaError(.fileReadCorruptFile)
        }
        return data
    }
    func request(_ json: [String:Any]) async throws -> JSON { try await send(json); return try await read() }
    func end() async {
        lifecycle.withLock { ending = true }
        await withCheckedContinuation { continuation in
            queue.async {
                try? self.input.fileHandleForWriting.close()
                if self.exited.wait(timeout:.now()+2) == .timedOut {
                    if self.process.isRunning { self.process.terminate() }
                    self.exited.wait()
                }
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
    var meetingURL = "https://meeting.example/2"
    var pageState = "present", sourceID = "remote"
    /// false: the page's new document has not counted its sources yet (0.2.12 sends the row
    /// with sourceCountKnown false after a navigation).
    var countKnown = true
    /// The probe's call (D52): each profile is its own call, since a lost recording holds its
    /// call by tab and generation and every profile uses tab 2.
    let callGeneration: String
    var offsetBaseMs = 0
    var nextStartFails = false
    var sendAudioOnStart = true
    let verified: Bool
    private let browserDocument = "generated-chrome-"+UUID().uuidString.lowercased()
    private let sourceDocument = "generated-hook-"+UUID().uuidString.lowercased()
    private var signalSequence = 0
    init(root: URL, title: String, verified: Bool = false) throws {
        self.verified = verified
        self.root = root; self.title = title; callGeneration = "call-" + UUID().uuidString.lowercased()
        control = try CaptureProbeProcess("cassini-control-host",root:root)
    }
    /// Extension 0.2.12's capabilities (D51), without heartbeat-v1 (the probe stays silent for
    /// longer than the app's heartbeat allows) and resume-capture-v1 (no stage answers a resume).
    static let capabilities = ["independent-sessions-v1","call-evidence-v1","page-state-v1","multi-stream-v1"]
    func ready(active: Bool = true, interrupted: Bool = false) async throws {
        let capabilities = Self.capabilities + (verified ? ["call-signals-v1","verified-auto-admission-v1"] : [])
        try await control.send(["type":"hello","version":1,"capabilities":capabilities])
        if verified {
            let configure = try await control.read()
            try CaptureSelfTest.require(configure["type"]?.string == "configure","Verified profile requires negotiation")
            try await control.send(["type":"configured","capabilities":["call-signals-v1","verified-auto-admission-v1"]])
        }
        try await control.send(status(interrupted:interrupted))
        try await meetings(active)
    }
    func meetings(_ active: Bool) async throws {
        var entry: [String:Any] = ["tabId":2,"title":title,"url":meetingURL,"sourceCount":active ? 1 : 0,"sourceCountKnown":countKnown,"heard":active,
                                   "pageState":pageState,"callGeneration":callGeneration]
        if verified { entry["browserDocumentId"] = browserDocument; entry["documentGeneration"] = sourceDocument }
        try await control.send(["type":"meetings","meetings":active || audio != nil ? [entry] : []])
        if verified {
            let row: [String:Any] = ["tabId":2,"url":meetingURL,"documentGeneration":browserDocument,"sourceDocumentGeneration":sourceDocument,
                "remoteAudio":"separated","callEvidence":["state":active ? "active" : "inactive","reason":active ? "activeCall" : "callEnded",
                "adapter":["name":"Generated verified session","version":"1"],"callGeneration":callGeneration]]
            try await control.send(["type":"callSignals","browserInstance":"generated-profile-"+callGeneration,"sequence":signalSequence,"tabs":[row]])
            signalSequence += 1
        }
    }
    func status(interrupted: Bool = false) -> [String:Any] {
        var packet: [String:Any] = ["type":"status","recording":audio != nil,"tabId":audio == nil ? NSNull() : 2,"path":path as Any? ?? NSNull(),"message":"Fixture status"]
        let entry: [String:Any] = ["recording":audio != nil,"tabId":2,"path":path as Any? ?? NSNull(),"captureId":captureID as Any? ?? NSNull(),"message":"Fixture status","tracks":1,"stopping":false,
                                   "pageState":pageState,"callGeneration":callGeneration]
        packet["sessions"] = audio == nil ? [] : [entry]
        if interrupted { packet["interrupted"] = [entry] }
        return packet
    }
    func readNextCommand() async throws -> JSON {
        let command = try await control.read()
        guard let request = command["requestId"]?.string, let action = command["action"]?.string else { throw CocoaError(.fileReadCorruptFile) }
        try? FileHandle.standardError.write(contentsOf:Data("Capture fixture command: \(title) \(action) \(request)\n".utf8))
        return command
    }
    func performNext() async throws -> JSON { try await perform(readNextCommand()) }
    func perform(_ command: JSON) async throws -> JSON {
        guard let request = command["requestId"]?.string, let action = command["action"]?.string else { throw CocoaError(.fileReadCorruptFile) }
        if action == "start", nextStartFails {
            nextStartFails = false
            try await control.send(["type":"result","requestId":request,"ok":false,"error":"Generated start failure","status":status()])
            try await control.send(status())
            return command
        }
        if action == "start" {
            let token = UUID().uuidString.lowercased(), audio = try CaptureProbeProcess("cassini-browser-host",root:root)
            self.audio = audio; captureID = token; sequence = 0; sourceID = "remote"; offsetBaseMs = 0
            try CaptureSelfTest.require(command["keepOnNavigation"]?.bool == true,"Start must retain the original audio transport")
            try CaptureSelfTest.require(command["callGeneration"]?.string == callGeneration,"Start names the probe's call")
            var start: [String:Any] = ["type":"start","version":1,"independent":true,"captureId":token,"timelineOriginMs":Int(Date().timeIntervalSince1970*1000),"microphone":command["microphone"]?.bool ?? true,"title":title,"callGeneration":callGeneration]
            if verified { start["requestId"] = request; start["documentGeneration"] = sourceDocument }
            let started = try await audio.request(start)
            guard started["type"]?.string == "started" else { throw CocoaError(.fileWriteUnknown) }
            path = started["path"]?.string
            if sendAudioOnStart {
                _ = try await audio.request(["type":"track","id":"remote","label":"Generated remote","kind":"remote","sampleRate":8000,"channels":1])
                try await emit()
            }
        } else {
            if let audio {
                var stop: [String:Any] = ["type":"stop"]
                if let reason = command["reason"]?.string { stop["reason"] = reason }
                _ = try await audio.request(stop); await audio.end(); self.audio = nil
            }
        }
        let snapshot = status()
        try await control.send(["type":"result","requestId":request,"ok":true,"status":snapshot])
        try await control.send(snapshot)
        return command
    }
    func emit() async throws {
        guard let audio else { throw CocoaError(.fileReadUnknown) }
        let answer = try await audio.request(["type":"audio","id":sourceID,"sequence":sequence,"offsetMs":offsetBaseMs+sequence*100,"pcm":Data(repeating:0x12,count:1600).base64EncodedString()])
        guard answer["type"]?.string == "ack" else { throw CocoaError(.fileWriteUnknown) }
        sequence += 1
    }
    func page(_ state: String, active: Bool) async throws {
        pageState = state; try await control.send(status()); try await meetings(active)
    }
    func returnedSource(atMs: Int) async throws {
        guard let audio else { throw CocoaError(.fileReadUnknown) }
        sourceID = UUID().uuidString.lowercased(); sequence = 0; offsetBaseMs = atMs
        let reply = try await audio.request(["type":"track","id":sourceID,"label":"Returned remote","kind":"remote","sampleRate":8000,"channels":1])
        try CaptureSelfTest.require(reply["type"]?.string == "ack","The original audio transport accepts the returning frame")
        try await emit()
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
    /// E1: observe product state changes, with a deadline that can only fail.
    /// Capture snapshots also cover thread-safe owner changes and the generated
    /// driver's callbacks which are deliberately outside Observation itself.
    @MainActor private final class StateWait {
        private var continuation: CheckedContinuation<Void,Error>?
        private var deadline: DispatchWorkItem?
        private var condition: (() -> Bool)?
        func run(timeout: Double, message: String, condition: @escaping () -> Bool) async throws {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation; self.condition = condition
                let deadline = DispatchWorkItem { [self] in
                    finish(.failure(NSError(domain:"CaptureSelfTest",code:1,userInfo:[NSLocalizedDescriptionKey:message])))
                }
                self.deadline = deadline
                DispatchQueue.main.asyncAfter(deadline:.now()+timeout,execute:deadline)
                check()
            }
        }
        private func check() {
            guard continuation != nil else { return }
            let ready = withObservationTracking {
                _ = CaptureCollection.shared.captures
                _ = CaptureCollection.shared.peers
                return condition?() == true
            } onChange: { [self] in
                // Observation fires before mutation. Check the committed value
                // on the next actor turn, never a guessed settling interval.
                Task { @MainActor in check() }
            }
            if ready { finish(.success(())) }
        }
        private func finish(_ result: Result<Void,Error>) {
            guard let continuation else { return }
            self.continuation = nil; condition = nil; deadline?.cancel(); deadline = nil
            continuation.resume(with:result)
        }
    }
    static func wait(timeout: Double = 8, file: StaticString = #fileID, line: UInt = #line,
                     _ condition: @escaping @MainActor () -> Bool) async throws {
        try await StateWait().run(timeout:timeout,message:"Private capture state did not settle at \(file):\(line)",condition:condition)
    }
    static func run() async {
        guard CaptureFixture.enabled, let root = RecordingFixture.root else { NSApp.terminate(nil); return }
        let collection = CaptureCollection.shared
        var profiles: [CaptureProbeProfile] = []
        var routingRoots: [URL] = []
        var deferredRoot: URL?
        var report: [String:Any] = [:]
        var stage = "start protected service" {
            didSet { try? FileHandle.standardError.write(contentsOf:Data("CaptureSelfTest progress: \(stage)\n".utf8)) }
        }
        do {
            try await Task.detached {
                try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
            }.value
            LibraryStore.shared.start()
            let pipe = root.appendingPathComponent(".control")
            await collection.start(root:pipe)
            try require(collection.available,"Protected service started")
            var notificationReply: CheckedContinuation<Void,Never>?
            CaptureNotifications.authorizationFixture = {
                await withCheckedContinuation { notificationReply = $0 }
            }
            var microphoneReplies: [CheckedContinuation<Void,Never>] = []
            CaptureFixture.microphoneAuthorizationFixture = {
                await withCheckedContinuation { microphoneReplies.append($0) }
            }
            var autoEnabled = false
            let enableAuto = Task { try await collection.setAutoRecord(true); autoEnabled = true }
            try await wait { !microphoneReplies.isEmpty }
            try require(notificationReply == nil && !autoEnabled,"Automatic recording asks for microphone before optional notifications")
            microphoneReplies.removeFirst().resume()
            try await enableAuto.value
            try require(autoEnabled && notificationReply == nil,"Auto-record settings never wait for notification consent or ask before a capture starts")
            try await collection.setAutoRecord(false)
            report["autoRecordMicrophonePrecedesNotifications"] = true
            let one = try CaptureProbeProfile(root:pipe,title:"Generated profile one"), two = try CaptureProbeProfile(root:pipe,title:"Generated profile two")
            profiles = [one,two]
            try await one.ready(); try await two.ready()
            try await wait { collection.peers.filter(\.reconciled).count == 2 && collection.hasCalls }
            stage = "start two profiles"
            CaptureFixture.silentMicrophone = true
            CaptureFixture.microphoneDC = -2060.0/32768
            // Use the real first-start confirmation path with notification
            // consent held indefinitely. Native inputs remain generated RAM.
            RecordCoordinator.shared.showingFirst = true
            RecordCoordinator.shared.confirm()
            // Receiving the actual command is the delivery signal. Acceptance
            // remains gated until perform() sends the browser's result below.
            let firstStart = try await one.readNextCommand()
            try require(firstStart["action"]?.string == "start" && one.audio == nil && collection.starting,"First browser Start delivered while acceptance is gated")
            try require(notificationReply == nil,"No notification prompt before the browser accepts the first Start")
            report["firstStartDeliveredWhileAcceptanceGated"] = true
            _ = try await one.perform(firstStart); _ = try await two.performNext()
            try await wait { microphoneReplies.count == 2 }
            try require(notificationReply == nil,"Browser recording requests microphone before optional notification consent")
            let admitted = microphoneReplies; microphoneReplies.removeAll()
            CaptureFixture.microphoneAuthorizationFixture = nil
            admitted.forEach { $0.resume() }
            try await wait { collection.captures.count == 2 && collection.captures.values.allSatisfy { $0.key != nil && $0.snapshot.manifest.tracks.contains { $0.kind == "microphone" && $0.frames > 0 } } }
            try await wait { notificationReply != nil }
            try require(!RecordCoordinator.shared.showingFirst,"First confirmation dismissed while recording actually started")
            let framesBeforeConsent = collection.captures.values.reduce(UInt64(0)) { $0 + $1.owner.snapshot.manifest.tracks.reduce(UInt64(0)) { $0 + $1.frames } }
            try await one.emit(); try await two.emit()
            try await wait { collection.captures.values.reduce(UInt64(0), { $0 + $1.owner.snapshot.manifest.tracks.reduce(UInt64(0), { $0 + $1.frames }) }) > framesBeforeConsent }
            try require(notificationReply != nil,"Recording continues while the notification banner is unanswered")
            report["browserMicrophonePrecedesNotifications"] = true
            notificationReply?.resume(); notificationReply = nil
            CaptureNotifications.authorizationFixture = nil
            report["firstRecordingDoesNotWaitForNotifications"] = true
            try await one.emit(); try await two.emit()
            try await wait { LibraryStore.shared.meetings.filter { $0.state.lifecycle == .recording }.count == 2 }
            let first = try collection.captures.values.first { $0.snapshot.manifest.title == one.title }.unwrap()
            let second = try collection.captures.values.first { $0.snapshot.manifest.title == two.title }.unwrap()
            try require(first.snapshot.directory != second.snapshot.directory,"Profiles have distinct owned folders")
            report["twoProfilesSameTabIndependent"] = true
            let suggestionMeeting = try LibraryStore.shared.meetings.first { $0.id == first.snapshot.manifest.id }.unwrap()
            let suggestionView = MeetingView(model:MeetingDetailModel(meeting:suggestionMeeting,frozen:true),format:LibraryStore.shared.format)
            try require(!suggestionView.showsCompanionSuggestion,"A connected companion does not show Set up again")
            stage = "owned recording surfaces and silent-mic boundary"
            try require(RecordingOverview.active && RecordingOverview.recordCommandTitle == UXText.text("common.stop"),"File Record command reflects an owned recording")
            try require(LibraryMoveCoordinator.shared.requiresRecordingConfirmation,"Move requires confirmation during an owned capture")
            try await wait { LibraryStore.shared.selected.map { collection.captures[$0.id] != nil } == true }
            let originalMeeting = try LibraryStore.shared.meetings.first { $0.id == first.snapshot.manifest.id }.unwrap()
            let originalEditor = RecordingPageModel.editor(for:originalMeeting)
            let duplicates = root.appendingPathComponent(".same-id-other-root")
            let duplicate = try RecordingSession(parent:duplicates,title:"Other folder",source:"macos",id:first.snapshot.manifest.id)
            try duplicate.addTrack(id:"mic",label:"Mic",kind:"microphone",sampleRate:8000,channels:1)
            try duplicate.appendNative(id:"mic",pcm:Data(repeating:1,count:160),offsetMs:0); try duplicate.finish()
            try MeetingMetadataWriter(directory:duplicate.directory,id:duplicate.manifest.id).createIfNeeded()
            let otherMeeting = try LibraryScanner(root:duplicates).scan().meetings.first.unwrap()
            try require(originalEditor.owned != nil && RecordingPageModel.editor(for:otherMeeting).owned == nil,"Recording controls match the folder as well as UUID")
            report["ownedEditorUsesFolderIdentity"] = true
            MeetingNavigation.shared.open(originalMeeting)
            // Both inputs have admitted generated DC frames. Advance only the
            // silence clock so these browser recordings keep their media offsets.
            let ownedIDs = [first.snapshot.manifest.id, second.snapshot.manifest.id]
            collection.setMicrophoneUptimeForTesting(ownedIDs, at:0)
            collection.setMicrophoneUptimeForTesting(ownedIDs, at:19.98)
            try require(!RecordingOverview.microphoneSilent && !originalEditor.microphoneSilent,"Owned silent microphone is hidden before twenty seconds")
            collection.setMicrophoneUptimeForTesting(ownedIDs, at:20)
            try require(RecordingOverview.microphoneSilent && originalEditor.microphoneSilent,"Owned silent microphone is shown at twenty seconds")
            try require(RecordingMenuPayload(recorder:.shared,runtime:.shared).levels.first?.silent == true,"Menu uses the same owned silent-microphone state")
            CaptureFixture.silentMicrophone = false
            try await wait { !RecordingOverview.microphoneSilent && !originalEditor.microphoneSilent }
            collection.setMicrophoneUptimeForTesting(ownedIDs, at:nil)
            CaptureFixture.microphoneDC = 0
            report["micDCDoesNotMaskSilence"] = true
            report["ownedSilenceMatchesMenuAndPage"] = true
            stage = "background deferred move preserves unrelated work"
            let previous = root.deletingLastPathComponent().appendingPathComponent("CassiniDeferredCapture-" + UUID().uuidString)
            deferredRoot = previous
            let deferred = try RecordingSession(parent:previous,title:"Deferred copy",source:"macos")
            try deferred.addTrack(id:"mic",label:"Mic",kind:"microphone",sampleRate:8000,channels:1)
            try deferred.appendNative(id:"mic",pcm:Data(repeating:0,count:160),offsetMs:0); try deferred.finish()
            let deferredMetadata = try MeetingMetadataWriter(directory:deferred.directory,id:deferred.manifest.id)
            try deferredMetadata.createIfNeeded()
            try Data("{\"items\":[{\"speaker\":\"mic\",\"startMs\":0,\"endMs\":1,\"text\":\"Private\"}]}".utf8).write(to:deferred.directory.appendingPathComponent("transcript.json"))
            try deferredMetadata.transaction { $0["transcript"] = ["status":"done","reference":["kind":"sidecar","file":"transcript.json","format":"cassini.words.v1"]] }
            try LibraryLocation(primary:root,previous:[previous],pendingMoves:[.init(source:previous,folderName:deferred.directory.lastPathComponent)]).write(file:LibraryLaunchContext.locationFile)
            LibraryStore.shared.reloadLocation()
            try await wait { LibraryStore.shared.loaded }
            MeetingNavigation.shared.open(originalMeeting)
            let exporter = MeetingExportCoordinator.shared
            exporter.show(otherMeeting)
            try require(exporter.showing,"Private export presentation is active before background Move")
            LibraryMoveCoordinator.shared.maybeRetryDeferred()
            try await wait { !LibraryMoveCoordinator.shared.busy && LibraryMoveCoordinator.shared.waitingCount == 0 }
            try require(exporter.showing && MeetingNavigation.shared.detail?.meeting.folder.standardizedFileURL.path == originalMeeting.folder.standardizedFileURL.path,"Background Move keeps unrelated navigation and export presentation")
            try require(FileManager.default.fileExists(atPath:root.appendingPathComponent(deferred.directory.lastPathComponent).path),"Deferred recording moved to the Library")
            exporter.cancel()
            report["deferredMovePreservesUnrelatedViewAndExport"] = true
            stage = "change per-meeting sources"
            try await collection.select(first.snapshot.manifest.id,me:false,others:true)
            let micEnd = collection.captures[first.snapshot.manifest.id]!.snapshot.manifest.tracks.filter { $0.kind == "microphone" }.reduce(UInt64(0)) { $0 + $1.frames }
            try await one.emit() // Real browser request/ack is the admission barrier.
            try require(collection.captures[first.snapshot.manifest.id]!.snapshot.manifest.tracks.filter { $0.kind == "microphone" }.reduce(UInt64(0)) { $0 + $1.frames } == micEnd,"Me off stops native admission")
            stage = "reject unavailable replacement input"
            let beforeChoice = first.owner.snapshot.manifest
            CaptureFixture.microphoneStartsAllowed = false
            // D58 (M16): a refused turn-on does not fail the selection. It returns the side's
            // code, keeps the previous selection and is recorded once, at the ask time.
            let refusalsBefore = first.owner.snapshot.manifest.refusals?.count ?? 0
            let refusedChoice = try await collection.select(first.snapshot.manifest.id,me:true,others:false)
            CaptureFixture.microphoneStartsAllowed = true
            try require(refusedChoice[.me] != nil && refusedChoice[.others] == nil && !first.owner.snapshot.me && first.owner.snapshot.others,"Failed microphone keeps Others selected")
            let refusals = first.owner.snapshot.manifest.refusals ?? []
            try require(refusals.count == refusalsBefore + 1 && refusals.last?.side == "me" && refusals.last?.code == refusedChoice[.me],"Refused microphone is recorded once as a me refusal")
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
            try require(MeetingNavigation.shared.detail == nil,"Stop returns the viewed recording to the Library")
            try require(RecordingOverview.saving && !LibraryMoveCoordinator.shared.canChoose,"Move is disabled while an owned recording saves")
            report["ownedStopReturnsToLibraryBeforeFlush"] = true
            try await wait { first.owner.snapshot.manifest.tracks.filter { $0.kind == "microphone" }.allSatisfy { $0.ended == true } }
            let stoppedMicFrames = first.owner.snapshot.manifest.tracks.filter { $0.kind == "microphone" }.reduce(UInt64(0)) { $0 + $1.frames }
            try await two.emit() // Another source progresses while this tail remains open.
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
            try await wait { !collection.starting }
            try require(collection.captures.count == 1 && automatic.isEmpty,"Recovery does not auto-restore browser capture")
            try require(fallbacks == [second.snapshot.manifest.id],"Actual system fallback is announced exactly once (got \(fallbacks.count))")
            report["fallbackAndWorkerRecoveryKeepOneFolder"] = true
            collection.stop(second.snapshot.manifest.id)
            _ = try await two.performNext()
            await collection.stopAndWait()
            try await wait { collection.captures.isEmpty }
            stage = "auto-start new call and notification Stop"
            try await one.meetings(false); try await two.meetings(false)
            try await wait { !collection.hasCalls }
            stage = "legacy companion requires manual Record"
            let legacy = try CaptureProbeProfile(root:pipe,title:"Generated legacy manual session")
            profiles.append(legacy)
            try await legacy.ready()
            try await wait { collection.hasCalls }
            try require(collection.captures.isEmpty && automatic.isEmpty,"Unverified inventory never starts automatically")
            try await collection.record()
            _ = try await legacy.performNext()
            try await wait { collection.captures.count == 1 && !collection.starting }
            try require(automatic.isEmpty,"Explicit Record remains manual with a legacy companion")
            collection.stop(try collection.captures.keys.first.unwrap())
            _ = try await legacy.performNext()
            await collection.stopAndWait()
            try await legacy.meetings(false)
            try await wait { collection.captures.isEmpty && !collection.hasCalls }
            report["legacyAutomaticDeniedManualAllowed"] = true
            stage = "verified auto-start and notification Stop"
            let verified = try CaptureProbeProfile(root:pipe,title:"Generated verified automatic session",verified:true)
            profiles.append(verified)
            try await verified.ready()
            _ = try await verified.performNext()
            try await wait { collection.captures.count == 1 && automatic.count == 1 }
            let automaticID = try collection.captures.keys.first.unwrap()
            let stopsBeforeDrain = CaptureFixture.stopRequests
            CaptureNotifications.handle(action:"stop",id:automaticID)
            // No suspension: the Stop task cannot finish before these polls.
            collection.pollLifetimeForTesting(at:ProcessInfo.processInfo.systemUptime)
            collection.pollLifetimeForTesting(at:ProcessInfo.processInfo.systemUptime)
            try require(CaptureFixture.stopRequests == stopsBeforeDrain+1,"Polling an ending automatic capture must not request Stop again")
            report["endingAutomaticCaptureStopsOnce"] = true
            _ = try await verified.performNext()
            await collection.stopAndWait()
            try await wait { collection.captures.isEmpty }
            report["newCallAutoStartAndNotificationStop"] = true
            try await verified.meetings(false)
            try await collection.setAutoRecord(false)
            try await one.meetings(false); try await two.meetings(false)
            try await wait { !collection.hasCalls }
            for transition in ["expiry","cancel"] {
                stage = "separated automatic admission closes during microphone permission: "+transition
                try await collection.setAutoRecord(true)
                let announcementCount = automatic.count, microphoneStarts = CaptureFixture.microphoneStarts
                let (entered, enteredEvent) = AsyncStream<Void>.makeStream(bufferingPolicy:.bufferingNewest(1))
                let (finished, finishedEvent) = AsyncStream<(Bool,Bool)>.makeStream(bufferingPolicy:.bufferingNewest(1))
                var permission: CheckedContinuation<Void,Never>?
                CaptureFixture.microphoneAuthorizationFixture = {
                    await withCheckedContinuation { reply in
                        permission = reply; enteredEvent.yield(()); enteredEvent.finish()
                    }
                }
                CaptureFixture.createdFinished = { _,problem,admitted in
                    finishedEvent.yield((problem,admitted)); finishedEvent.finish()
                }
                defer {
                    CaptureFixture.microphoneAuthorizationFixture = nil; CaptureFixture.createdFinished = nil
                    CaptureFixtureAdmissionClock.shared.reset()
                }
                let pending = try CaptureProbeProfile(root:pipe,title:"Generated pending "+transition,verified:true)
                pending.sendAudioOnStart = false; profiles.append(pending)
                try await pending.ready(); _ = try await pending.performNext()
                for await _ in entered { break } // Actual permission suspension, not a settling delay.
                try await wait { collection.peers.flatMap(\.captures).contains { $0.captureID == pending.captureID } }
                let pendingID = try collection.captures.keys.first.unwrap()
                if transition == "expiry" { CaptureFixtureAdmissionClock.shared.advance(by:10) }
                else { collection.stop(pendingID) }
                permission?.resume(); permission = nil
                for await (problem,admitted) in finished {
                    try require(!problem && !admitted,"Withdrawn automatic startup is cancellation, never a source failure or accepted input")
                }
                try require(automatic.count == announcementCount,"No automatic-start announcement before an accepted input")
                try require(CaptureFixture.microphoneStarts == microphoneStarts,"No microphone input may start after withdrawal")
                try await collection.setAutoRecord(false)
                _ = try await pending.performNext()
                await collection.stopAndWait()
                CaptureFixture.microphoneAuthorizationFixture = nil; CaptureFixture.createdFinished = nil
                CaptureFixtureAdmissionClock.shared.reset()
                try await pending.meetings(false)
                try await wait { collection.captures.isEmpty && !collection.isSaving && !collection.hasCalls }
                try require(!collection.recordFailed,"A withdrawn automatic startup is not a failed manual Record")
            }
            report["separatedAdmissionCancellationIsQuiet"] = true
            stage = "partial failure: discover both calls"
            one.nextStartFails = true
            try await one.meetings(true); try await two.meetings(true)
            try await wait { collection.peers.flatMap(\.meetings).filter { $0.sourceCount > 0 }.count == 2 }
            try await collection.record()
            _ = try await one.performNext(); _ = try await two.performNext()
            stage = "partial failure: settle one failure and one owned recording"
            try await wait { collection.failedMeetings.count == 1 && collection.captures.count == 1 && !collection.starting && collection.captures.values.allSatisfy { $0.key != nil } }
            try require(!collection.recordFailed,"One failed meeting must not become an all-failed message")
            let successfulToken = two.captureID, retryKey = try collection.failedMeetings.keys.first.unwrap()
            collection.retry(retryKey)
            try require(collection.starting,"Targeted retry keeps Try again disabled while pending")
            collection.retry(retryKey) // A second click cannot issue another command.
            _ = try await one.performNext()
            stage = "partial retry: settle two owned recordings"
            try await wait { collection.captures.count == 2 && collection.failedMeetings.isEmpty && collection.captures.values.allSatisfy { $0.key != nil } }
            try require(two.captureID == successfulToken,"Retry must not restart the successful meeting")
            stage = "hang up while the tab stays open"
            try await one.meetings(false)
            try await wait { collection.peers.flatMap(\.meetings).contains { $0.title == one.title && $0.sourceCount == 0 } }
            // D52: a heard call that shows zero sources ends after 30 s, not at once.
            let hungUpAt = ProcessInfo.processInfo.systemUptime
            collection.pollLifetimeForTesting(at:hungUpAt)
            collection.pollLifetimeForTesting(at:hungUpAt+29.5)
            try require(collection.captures.count == 2,"A hung-up call keeps its 30-second grace")
            collection.pollLifetimeForTesting(at:hungUpAt+30.01)
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
            stage = "retry failure after the successful meeting has stopped"
            one.nextStartFails = true
            try await one.meetings(true); try await two.meetings(true)
            try await wait { collection.peers.flatMap(\.meetings).filter { $0.sourceCount > 0 }.count == 2 }
            try await collection.record(); _ = try await one.performNext(); _ = try await two.performNext()
            // Command completion precedes the next peer snapshot. This case
            // stops an admitted recording, so await its browser association
            // before demanding that the fixture receives a browser Stop.
            try await wait { collection.failedMeetings.count == 1 && collection.captures.count == 1 && !collection.starting && collection.captures.values.allSatisfy { $0.key != nil } }
            let failedKey = try collection.failedMeetings.keys.first.unwrap()
            let successful = try collection.captures.keys.first.unwrap()
            collection.stop(successful); _ = try await two.performNext()
            await collection.stopAndWait()
            one.nextStartFails = true
            collection.retry(failedKey)
            try require(collection.starting,"Retry owns its pending attempt")
            _ = try await one.performNext()
            try await wait { collection.recordFailed && !collection.starting }
            try require(collection.captures.isEmpty,"A failed retry after Stop does not inherit the prior success")
            report["failedRetryDoesNotInheritStoppedSuccess"] = true
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
            let expiringID = expiring.snapshot.manifest.id
            await one.control.end()
            try await wait { !collection.peers.contains { $0.id == expiring.key?.peer } }
            // D52: the 120 s return grace runs from when the call disappeared (the policy's stamp);
            // the earlier transport loss was cleared by the still-present call.
            try await wait { collection.captures[expiringID]?.callPolicy.missingSince != nil }
            let disappeared = try (collection.captures[expiringID]?.callPolicy.missingSince).unwrap()
            collection.pollLifetimeForTesting(at:disappeared+119.99)
            try require(collection.captures[expiringID] != nil,"The 120-second grace cannot expire early")
            collection.pollLifetimeForTesting(at:disappeared+120.01)
            try await wait { collection.captures.isEmpty }
            let expiredManifest = try RecordingLoader.load(directory:expiring.owner.snapshot.directory)
            try require(expiredManifest.events?.last?.reason == "pageGone","A call that never returns ends with pageGone")
            report["unobservedFallbackExpires"] = true
            stage = "original-transport return and closed tab"
            try await collection.setAutoRecord(false)
            let modern = try CaptureProbeProfile(root:pipe,title:"Returning call")
            profiles.append(modern); try await modern.ready()
            try await wait { collection.hasCalls }
            try await collection.record(); _ = try await modern.performNext()
            try await wait { collection.captures.count == 1 && collection.captures.values.first?.peerKnown == true }
            let returning = try collection.captures.values.first.unwrap(), returningID = returning.snapshot.manifest.id
            // A rapid reload as 0.2.12 reports it: each page state comes with the new document's
            // row, whose count is not known yet, so the old document's positive count can never
            // read as a visibly ongoing call that clears the loss. Present with zero sources then
            // keeps the loss (D52 reload-present-zero-retains-return-grace) and falls back.
            let originalCaptureID = try modern.captureID.unwrap()
            // Hold the first native loss until the returning status cancels
            // its source revision. This was otherwise a scheduler-dependent
            // failure: the owner stayed browserAlive and fallback never began.
            var heldLoss: CheckedContinuation<Void,Never>?
            defer { CaptureFixture.beforeBrowserLoss = nil; heldLoss?.resume(); heldLoss = nil }
            CaptureFixture.beforeBrowserLoss = {
                CaptureFixture.beforeBrowserLoss = nil
                await withCheckedContinuation { heldLoss = $0 }
            }
            modern.countKnown = false
            for page in ["navigating","present"] {
                modern.pageState = page
                var advisory = modern.status(); advisory.removeValue(forKey:"sessions"); advisory["pageState"] = page
                try await modern.control.send(advisory)
                try await modern.meetings(false)
                if page == "navigating" { try await wait { heldLoss != nil } }
            }
            modern.meetingURL = "https://meeting.example/reloaded-call"
            modern.countKnown = true
            try await modern.meetings(false)
            try await wait { collection.peers.first { $0.id == returning.key?.peer }?.meetings.first?.sourceCount == 0 && collection.peers.first { $0.id == returning.key?.peer }?.meetings.first?.url == modern.meetingURL }
            heldLoss?.resume(); heldLoss = nil
            try require(collection.peers.first { $0.id == returning.key?.peer }?.captures.first?.captureID == originalCaptureID,"ID-less lifecycle reports retain the original capture through a URL change")
            report["rapidReloadKeepsCaptureIdentity"] = true
            try await wait { !returning.owner.snapshot.browserAlive }
            let loss = try returning.owner.snapshot.browserLostUptime.unwrap()
            collection.pollLifetimeForTesting(at:loss+2.01)
            try await wait { returning.owner.snapshot.usingSystem }
            try require(returning.owner.snapshot.phase == .recording && collection.captures[returningID] != nil,"Rapid return retains the original recording and long grace")
            report["rapidReloadInvalidatesCachedSources"] = true
            try await modern.returnedSource(atMs:Int((loss+2.2-returning.originUptime)*1000))
            try await modern.page("present",active:true)
            try await wait { collection.peers.first { $0.id == returning.key?.peer }?.meetings.first?.pageState == .present }
            collection.pollLifetimeForTesting(at:loss+2.1)
            try await wait { returning.owner.snapshot.browserAlive }
            try await modern.emit()
            try require(returning.owner.snapshot.directory == returning.snapshot.directory,"Return keeps the same folder")
            try require(returning.owner.snapshot.manifest.events?.last(where:{ $0.type == "othersSource" })?.reason == "restored","Return publishes the atomic restored event")
            report["originalTransportRestoresSameFolder"] = true
            try await collection.select(returningID,me:true,others:false)
            try await modern.page("navigating",active:false)
            try await wait { !returning.owner.snapshot.browserAlive }
            // The return follows the second navigation's real stamp even on a slow runner, and
            // the select below starts only after the positive inventory has arrived: a later
            // count change would otherwise cancel its source change mid-authorization.
            try await modern.returnedSource(atMs:Int((max(loss+4.2,ProcessInfo.processInfo.systemUptime)-returning.originUptime)*1000))
            try await modern.page("present",active:true)
            try await wait {
                let meeting = collection.peers.first { $0.id == returning.key?.peer }?.meetings.first
                return meeting?.pageState == .present && meeting?.sourceCount == 1
            }
            collection.pollLifetimeForTesting(at:loss+4.1)
            try require(!returning.owner.snapshot.others && !returning.owner.snapshot.usingSystem,"The others stays off after return")
            report["othersOffStaysOff"] = true
            try await collection.select(returningID,me:true,others:true)
            let systemTracks = returning.owner.snapshot.manifest.tracks.filter { $0.kind == "system" }.count
            try await modern.page("closed",active:false)
            try await wait { collection.peers.first { $0.id == returning.key?.peer }?.captures.first?.pageState == .closed }
            collection.pollLifetimeForTesting(at:loss+6.2)
            let closed = try await modern.performNext()
            try require(closed["reason"]?.string == "tabClosed","Closed tab sends its real terminal reason")
            try await wait { collection.captures.isEmpty }
            let modernEnded = try RecordingLoader.load(directory:returning.owner.snapshot.directory)
            try require(modernEnded.events?.last?.reason == "tabClosed","Closed tab persists its end reason")
            try require(modernEnded.tracks.filter { $0.kind == "system" }.count == systemTracks,"Closed tab must not start a new computer-sound fallback")
            report["closedTabStopsWithoutSystemFallback"] = true
            report["stopAfterReloadedURLRoutesWithoutForcedFinalization"] = true
            try await modern.meetings(false)
            stage = "return while system permission remains unanswered"
            let waiting = try CaptureProbeProfile(root:pipe,title:"Pending system permission")
            profiles.append(waiting); try await waiting.ready()
            try await wait { collection.hasCalls }
            try await collection.record(); _ = try await waiting.performNext()
            try await wait {
                collection.captures.count == 1 && collection.captures.values.first?.peerKnown == true &&
                collection.captures.values.first?.owner.snapshot.manifest.tracks.contains { $0.kind == "microphone" && $0.frames > 0 } == true
            }
            let permissionCapture = try collection.captures.values.first.unwrap()
            let previousSystemStarts = CaptureFixture.systemStarts
            let previousMicStarts = CaptureFixture.microphoneStarts
            CaptureFixture.holdSystemPermission = true
            try await waiting.page("navigating",active:false)
            try await wait { !permissionCapture.owner.snapshot.browserAlive }
            let pendingLoss = try permissionCapture.owner.snapshot.browserLostUptime.unwrap()
            collection.pollLifetimeForTesting(at:pendingLoss+2.01)
            try await wait { CaptureFixture.systemPermission != nil }
            try await waiting.returnedSource(atMs:Int((pendingLoss+2.2-permissionCapture.originUptime)*1000))
            try await waiting.page("present",active:true)
            try await wait { permissionCapture.owner.snapshot.browserAlive }
            try require(CaptureFixture.systemPermission != nil,"Return cannot require a reply to the OS prompt")
            try await wait { permissionCapture.owner.snapshot.manifest.events?.last(where:{ $0.type == "othersSource" }).map { $0.source == "browser" && $0.reason == "restored" } == true }
            try require(CaptureFixture.systemStarts == previousSystemStarts,"Cancelled permission cannot start system input")
            try require(CaptureFixture.microphoneStarts == previousMicStarts,"Return leaves the original microphone running")
            let permissionCompletions = CaptureFixture.systemAuthorizationCompletions
            CaptureFixture.holdSystemPermission = false
            CaptureFixture.systemPermission?.resume(); CaptureFixture.systemPermission = nil
            try await wait { CaptureFixture.systemAuthorizationCompletions > permissionCompletions }
            try await permissionCapture.input.update() // Lifecycle queue drained after the actual permission response.
            try require(CaptureFixture.systemStarts == previousSystemStarts && !permissionCapture.owner.snapshot.usingSystem,"Late permission does not revive cancelled fallback")
            report["returnCancelsPendingSystemPermission"] = true
            collection.stop(permissionCapture.snapshot.manifest.id); _ = try await waiting.performNext()
            try await wait { collection.captures.isEmpty }
            try await waiting.meetings(false)
            stage = "call gone across a control reconnect stops native inputs"
            let reconnecting = try CaptureProbeProfile(root:pipe,title:"Control reconnect hangup")
            profiles.append(reconnecting); try await reconnecting.ready()
            try await wait {
                let active = collection.peers.filter(\.reconciled).flatMap(\.meetings).filter { $0.sourceCount > 0 }
                return !active.isEmpty && active.allSatisfy { $0.title == reconnecting.title }
            }
            try await collection.record(); _ = try await reconnecting.performNext()
            try await wait { collection.captures.count == 1 && collection.captures.values.first?.key != nil }
            let hungUp = try collection.captures.values.first.unwrap()
            await reconnecting.control.end()
            // No new browser packets: the call hangs up while only management
            // is disconnected, without a page navigation or audio-host exit.
            try await wait { hungUp.owner.snapshot.usingSystem }
            reconnecting.control = try CaptureProbeProcess("cassini-control-host",root:pipe)
            try await reconnecting.control.send(["type":"hello","version":1,"capabilities":CaptureProbeProfile.capabilities])
            try await reconnecting.control.send(reconnecting.status())
            try await wait {
                collection.peers.contains { peer in
                    peer.reconciled && peer.meetings.isEmpty && peer.captures.contains { $0.captureID == reconnecting.captureID }
                }
            }
            let unknownInventoryTime = ProcessInfo.processInfo.systemUptime
            collection.pollLifetimeForTesting(at:unknownInventoryTime+2.25)
            try require(collection.captures[hungUp.snapshot.manifest.id] != nil && hungUp.input.hasRunningInputs,"Present status without an inventory is not a confirmed hangup")
            try await reconnecting.meetings(false)
            try await wait { collection.peers.flatMap(\.meetings).contains { $0.title == reconnecting.title && $0.sourceCount == 0 } }
            // D52: while the loss is pending, a present page with zero sources keeps the 120 s
            // return grace (a reload may still bring the call back), measured from the control loss.
            let gone = try (collection.captures[hungUp.snapshot.manifest.id]?.callPolicy.missingSince).unwrap()
            collection.pollLifetimeForTesting(at:gone+119.99)
            try require(collection.captures[hungUp.snapshot.manifest.id] != nil,"Present/zero during a pending loss keeps the return grace")
            collection.pollLifetimeForTesting(at:gone+120.01)
            let hangupStop = try await reconnecting.performNext()
            try require(hangupStop["reason"]?.string == "pageGone","The call that never came back ends as pageGone")
            try await wait { collection.captures.isEmpty }
            try require(!hungUp.input.hasRunningInputs,"Stop ends both native microphone and computer-sound inputs")
            let hungUpManifest = try RecordingLoader.load(directory:hungUp.owner.snapshot.directory)
            try require(hungUpManifest.events?.last?.reason == "pageGone","The end reason is persisted")
            try require(hungUpManifest.tracks.contains { $0.kind == "system" && $0.frames > 0 },"The regression exercised actual system fallback before reconnecting")
            report["reconnectedLostCallStopsNativeInputs"] = true
            try await reconnecting.meetings(false)
            stage = "first browser packet with denied microphone"
            CaptureFixture.microphoneAllowed = false
            try await two.meetings(true)
            try await wait { collection.hasCalls }
            try await collection.record(); _ = try await two.performNext()
            try await wait { collection.captures.count == 1 && !collection.starting }
            let browserOnly = try collection.captures.values.first.unwrap()
            try await wait { collection.activity[browserOnly.snapshot.manifest.id] == .recording && LibraryStore.shared.meetings.contains { $0.id == browserOnly.snapshot.manifest.id && $0.state.lifecycle == .recording } }
            try require(browserOnly.owner.snapshot.manifest.tracks.filter { $0.kind == "remote" }.reduce(UInt64(0)) { $0 + $1.frames } == 800,"The sole browser packet is visible without a native input")
            try require(!collection.recordFailed,"Actual browser PCM clears the failed-start state")
            report["firstBrowserPacketMakesRecordingVisible"] = true
            collection.stop(browserOnly.snapshot.manifest.id); _ = try await two.performNext()
            await collection.stopAndWait()
            try await two.meetings(false); try await wait { !collection.hasCalls }
            stage = "denied microphone and disk reserve"
            CaptureFixture.systemBuffersAllowed = false
            let beforeMicStarts = CaptureFixture.microphoneStarts
            try await collection.record()
            // record() can return before the start has written its othersSource event (D66
            // mac-P0-2, E1): wait for that event, then read state once. Not `!starting`: with the
            // microphone denied and system buffers held back, the start stays `.preparing` until
            // the first frames arrive, which this stage releases only after its checks.
            try await wait {
                collection.captures.values.first?.owner.snapshot.manifest.events?.last(where:{ $0.type == "othersSource" })?.source == "none"
            }
            let pending = try collection.captures.values.first.unwrap()
            let pendingMeeting = try LibraryScanner(root:root).scan().meetings.first { $0.id == pending.snapshot.manifest.id }.unwrap()
            let pendingEditor = RecordingPageModel.editor(for:pendingMeeting)
            try require(pending.owner.snapshot.manifest.events?.last(where:{ $0.type == "othersSource" })?.source == "none","System fixture has not delivered its first buffer")
            try require(!pendingEditor.othersUnavailable && pendingEditor.othersPathTitle == UXText.text("whatIsRecorded.othersHeard.system.title") && pendingEditor.othersPathBody == UXText.text("whatIsRecorded.othersHeard.system.description"),"Starting system audio does not claim permission was denied")
            CaptureFixture.systemBuffersAllowed = true
            report["pendingSystemSourceIsNotPermissionFailure"] = true
            try await wait { collection.captures.values.contains { $0.snapshot.manifest.source == "macos" && $0.snapshot.manifest.tracks.contains { $0.kind == "system" && $0.frames > 0 } } }
            try require(CaptureFixture.microphoneStarts == beforeMicStarts,"Denied microphone did not start a device driver")
            try require(collection.first?.input.failedSides.contains(.me) == true,"Permission warning remains distinct from selection")
            try require(fallbacks == [second.snapshot.manifest.id,expiring.snapshot.manifest.id,returningID,hungUp.snapshot.manifest.id],"Only the four browser losses announce fallback; a normal native start does not")
            report["nativeStartDoesNotReportFallback"] = true
            let nativeMenu = RecordingMenuPayload(recorder:.shared,runtime:.shared)
            try require(nativeMenu.sourceLines?.contains(UXText.text("errors.othersFallback.line")) != true,"A normal native menu does not claim browser fallback")
            stage = "denied microphone is not silence"
            // Exercise the silence threshold with the same input state rather
            // than waiting twenty seconds for an invariant on denied input.
            guard let deniedID = collection.first?.snapshot.manifest.id else { throw CocoaError(.fileReadUnknown) }
            collection.ageMicrophoneForTesting(deniedID,seconds:21)
            try require(!RecordingOverview.microphoneSilent && RecordingMenuPayload(recorder:.shared,runtime:.shared).levels.first?.silent == false,"Denied microphone never becomes a silence warning")
            report["deniedMicIsNotSilent"] = true
            let total: UInt64 = 100 << 30
            collection.applyDiskBudgetForTesting(DiskBudget(total:total,free:total/50 + 16000*60*10,bytesPerSecond:16000))
            try require(RecordingOverview.diskLine == UXText.text("errors.diskLow.line",["n":"10"]),"Library and preview use the owned disk warning")
            report["ownedDiskWarningUsesOverview"] = true
            collection.applyDiskBudgetForTesting(DiskBudget(total:100<<30,free:0,bytesPerSecond:16000))
            await collection.stopAndWait()
            report["deniedMicKeepsOthersRecording"] = true
            try require(collection.diskStopped && RecordingOverview.diskLine == UXText.text("errors.diskStopped.line") && RecordingOverview.libraryDiskLine == nil,"Reserve Stop keeps its reason without duplicating the Library banner")
            report["diskReserveStopsAndKeeps"] = true
            try await wait { collection.captures.isEmpty }
            let before = try folders(root)
            stage = "nothing started leaves no folder"
            CaptureNotifications.shared.resetAuthorizationForFixture()
            var failedStartNotificationRequests = 0
            CaptureNotifications.authorizationFixture = { failedStartNotificationRequests += 1 }
            CaptureFixture.systemAllowed = false
            try await collection.record()
            try await wait { collection.recordFailed && collection.captures.isEmpty }
            let after = try folders(root)
            try require(after == before,"No samples means no new Library folder")
            await Task.yield()
            try require(failedStartNotificationRequests == 0,"Failed native inputs never request notification consent")
            report["failedNativeStartSkipsNotifications"] = true
            report["nothingStartedLeavesNoLibraryEntry"] = true
            stage = "failed System input retains microphone and permission description"
            CaptureFixture.microphoneAllowed = true
            try await collection.record()
            try await wait { collection.first?.snapshot.manifest.tracks.contains { $0.kind == "microphone" && $0.frames > 0 } == true }
            try await wait { failedStartNotificationRequests == 1 }
            CaptureNotifications.authorizationFixture = nil
            let partial = try collection.captures.values.first.unwrap()
            let partialMeeting = try LibraryScanner(root:root).scan().meetings.first { $0.id == partial.snapshot.manifest.id }.unwrap()
            let partialEditor = RecordingPageModel.editor(for:partialMeeting)
            try require(partialEditor.othersUnavailable && partialEditor.othersPathBody == UXText.text("errors.othersPermission.line"),"Actual System failure shows permission guidance while microphone continues")
            await collection.stopAndWait()
            report["failedSystemSourceShowsPermissionGuidance"] = true
            for profile in profiles { await profile.finish() }
            profiles = []
            try await wait { !collection.connected }
            try require(suggestionView.showsCompanionSuggestion,"An undismissed setup suggestion returns when disconnected")
            report["companionSuggestionTracksConnection"] = true
            stage = "Library move admission"
            CaptureFixture.microphoneAllowed = true; CaptureFixture.systemAllowed = true
            let startsBeforeMove = CaptureFixture.microphoneStarts + CaptureFixture.systemStarts
            collection.setLibraryMoveBlocked(true)
            var moveRejected = false
            do { try await collection.record() } catch { moveRejected = true }
            collection.setLibraryMoveBlocked(false)
            try require(moveRejected && collection.captures.isEmpty && CaptureFixture.microphoneStarts + CaptureFixture.systemStarts == startsBeforeMove,"Move guard rejects capture before any input starts")
            report["activeMoveRejectsRecording"] = true
            stage = "relocated Library and retained bookmark"
            let destination = root.deletingLastPathComponent().appendingPathComponent("CassiniCaptureDestination-" + UUID().uuidString)
            let renamed = destination.appendingPathExtension("renamed")
            routingRoots = [destination,renamed]
            try FileManager.default.createDirectory(at:destination,withIntermediateDirectories:false)
            let bookmark = try destination.bookmarkData(options:.withSecurityScope,includingResourceValuesForKeys:nil,relativeTo:nil)
            try LibraryLocation(primary:destination,bookmarks:[destination.path:bookmark]).write(file:LibraryLaunchContext.locationFile)
            try await collection.record()
            try await wait { collection.first?.snapshot.manifest.tracks.contains { $0.frames > 0 } == true }
            try require(collection.first?.snapshot.directory.deletingLastPathComponent().resolvingSymlinksInPath().path == destination.resolvingSymlinksInPath().path,"Recording uses the relocated Library")
            let relocatedID = try (collection.first?.snapshot.manifest.id).unwrap()
            try await wait { LibraryStore.shared.meetings.contains { $0.id == relocatedID && $0.state.lifecycle == .recording } }
            await collection.stopAndWait()
            try FileManager.default.moveItem(at:destination,to:renamed)
            try await collection.record()
            try await wait { collection.first?.snapshot.manifest.tracks.contains { $0.frames > 0 } == true }
            try require(collection.first?.snapshot.directory.deletingLastPathComponent().resolvingSymlinksInPath().path == renamed.resolvingSymlinksInPath().path,"Capture follows the renamed bookmark")
            let renamedID = try (collection.first?.snapshot.manifest.id).unwrap()
            try await wait { LibraryStore.shared.meetings.contains { $0.id == renamedID && $0.state.lifecycle == .recording && $0.folder.deletingLastPathComponent().resolvingSymlinksInPath().path == renamed.resolvingSymlinksInPath().path } }
            try require(!FileManager.default.fileExists(atPath:destination.path),"Old published path is never recreated")
            let notificationCount = CaptureNotifications.savedFixtureTitles.count
            await RecordCoordinator.shared.stopFromShortcut(notify:true).value
            try require(CaptureNotifications.savedFixtureTitles.count == notificationCount + 1,"Shortcut reports the saved owned meeting after finalization")
            report["shortcutNotifiesAfterOwnedSave"] = true
            report["recordingFollowsRelocatedBookmark"] = true
            stage = "offline Library"
            try FileManager.default.removeItem(at:renamed)
            var offlineRejected = false
            do { try await collection.record() } catch { offlineRejected = true }
            try require(offlineRejected && collection.captures.isEmpty,"Offline Library rejects recording")
            try require(!FileManager.default.fileExists(atPath:destination.path) && !FileManager.default.fileExists(atPath:renamed.path),"Offline Library is not recreated")
            report["offlineLibraryIsNotRecreated"] = true
            try LibraryLocation(primary:root).write(file:LibraryLaunchContext.locationFile)
            LibraryStore.shared.reloadLocation()
            stage = "shutdown"
            await collection.shutdown()
            LibraryStore.shared.stop()
            report["audioDevicesOpened"] = false; report["browserProfilesTouched"] = false
            report["nativeMessagingProcesses"] = true; report["exactProductProfile"] = true
            try FileHandle.standardOutput.write(contentsOf:JSONSerialization.data(withJSONObject:report,options:.sortedKeys))
            try FileManager.default.removeItem(at:root)
            for url in routingRoots { try? FileManager.default.removeItem(at:url) }
            if let deferredRoot { try? FileManager.default.removeItem(at:deferredRoot) }
        } catch {
            // Snapshot before teardown retires peers/owners. These are private
            // generated fixture identities, not production recording telemetry.
            let state: [String:Any] = ["stage":stage,"starting":collection.starting,"recording":collection.isRecording,"recordFailed":collection.recordFailed,
                "failed":collection.failedMeetings.map { ["peer":$0.key.peer.uuidString,"tabId":$0.key.tabID,"title":$0.value] },
                "owned":collection.captures.values.map { ["id":$0.snapshot.manifest.id.uuidString,"phase":String(describing:$0.snapshot.phase),"frames":$0.snapshot.manifest.tracks.reduce(UInt64(0)) { $0+$1.frames },"browserAlive":$0.snapshot.browserAlive] as [String:Any] },
                "peers":collection.peers.map { ["id":$0.id.uuidString,"reconciled":$0.reconciled,"meetings":$0.meetings.map { ["tabId":$0.key.tabID,"sourceCount":$0.sourceCount] },"captures":$0.captures.count] as [String:Any] }]
            let diagnostics = (try? JSONSerialization.data(withJSONObject:state,options:[.sortedKeys])).flatMap { String(data:$0,encoding:.utf8) } ?? "unavailable"
            for profile in profiles { await profile.finish() }
            await collection.shutdown()
            for url in routingRoots { try? FileManager.default.removeItem(at:url) }
            if let deferredRoot { try? FileManager.default.removeItem(at:deferredRoot) }
            try? FileHandle.standardError.write(contentsOf:Data(("CaptureSelfTest [" + stage + "]: " + String(describing:error) + "\n" + diagnostics + "\n").utf8))
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
