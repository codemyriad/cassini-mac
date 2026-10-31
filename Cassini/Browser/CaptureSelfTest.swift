// SPDX-License-Identifier: GPL-3.0-or-later
#if DEBUG
import AppKit
import CassiniKit
import CassiniRecording
import CassiniLibrary
import Darwin

/// Native framing through the actual bundled executables; no capture APIs or
/// browser profiles are involved. All blocking pipe operations leave UI actor.
final class CaptureProbeProcess: @unchecked Sendable {
    private let process = Process(), input = Pipe(), output = Pipe(), errors = Pipe()
    private let queue = DispatchQueue(label:"io.codemyriad.cassini.capture-probe." + UUID().uuidString)
    private let lifecycle = NSLock()
    private var ending = false
    init(_ name: String, root: URL) throws {
        process.executableURL = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/" + name)
        process.environment = ["CASSINI_CONTROL_PIPE_ROOT":root.path]
        process.standardInput = input; process.standardOutput = output; process.standardError = errors
        let fd = output.fileHandleForReading.fileDescriptor, flags = fcntl(output.fileHandleForReading.fileDescriptor,F_GETFL)
        guard flags >= 0,fcntl(fd,F_SETFL,flags | O_NONBLOCK) == 0 else { throw POSIXError(.EIO) }
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
        try? FileHandle.standardError.write(contentsOf:Data("Capture fixture command: \(title) \(action) \(request)\n".utf8))
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
            let one = try CaptureProbeProfile(root:pipe,title:"Generated profile one"), two = try CaptureProbeProfile(root:pipe,title:"Generated profile two")
            profiles = [one,two]
            try await one.ready(); try await two.ready()
            try await wait { collection.peers.filter(\.reconciled).count == 2 && collection.hasCalls }
            stage = "start two profiles"
            CaptureFixture.silentMicrophone = true
            CaptureFixture.microphoneDC = -2060.0/32768
            var notificationReply: CheckedContinuation<Void,Never>?
            CaptureNotifications.authorizationFixture = {
                await withCheckedContinuation { notificationReply = $0 }
            }
            // Use the real first-start confirmation path with notification
            // consent held indefinitely. Native inputs remain generated RAM.
            RecordCoordinator.shared.showingFirst = true
            RecordCoordinator.shared.confirm()
            _ = try await one.performNext(); _ = try await two.performNext()
            try await wait { collection.captures.count == 2 && collection.captures.values.allSatisfy { $0.key != nil && $0.snapshot.manifest.tracks.contains { $0.kind == "microphone" && $0.frames > 0 } } }
            try await wait { notificationReply != nil }
            try require(!RecordCoordinator.shared.showingFirst,"First confirmation dismissed while recording actually started")
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
            stage = "owned recording surfaces and real silent-mic interval"
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
            try await Task.sleep(for:.seconds(20.25))
            try require(RecordingOverview.microphoneSilent && originalEditor.microphoneSilent,"Owned silent microphone is shown after twenty real seconds")
            try require(RecordingMenuPayload(recorder:.shared,runtime:.shared).levels.first?.silent == true,"Menu uses the same owned silent-microphone state")
            CaptureFixture.silentMicrophone = false
            try await wait { !RecordingOverview.microphoneSilent && !originalEditor.microphoneSilent }
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
            try require(MeetingNavigation.shared.detail == nil,"Stop returns the viewed recording to the Library")
            try require(RecordingOverview.saving && !LibraryMoveCoordinator.shared.canChoose,"Move is disabled while an owned recording saves")
            report["ownedStopReturnsToLibraryBeforeFlush"] = true
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
            let lostAt = try expiring.owner.snapshot.browserLostUptime.unwrap()
            await one.control.end()
            try await wait { !collection.peers.contains { $0.id == expiring.key?.peer } }
            collection.pollLifetimeForTesting(at:lostAt + 30.01)
            try await wait { collection.captures.isEmpty }
            report["unobservedFallbackExpires"] = true
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
            try require(fallbacks == [second.snapshot.manifest.id,expiring.snapshot.manifest.id],"Only the two browser losses announce fallback; a normal native start does not")
            report["nativeStartDoesNotReportFallback"] = true
            let nativeMenu = RecordingMenuPayload(recorder:.shared,runtime:.shared)
            try require(nativeMenu.sourceLines?.contains(UXText.text("errors.othersFallback.line")) != true,"A normal native menu does not claim browser fallback")
            stage = "denied microphone is not silence"
            try await Task.sleep(for:.seconds(20.25))
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
            CaptureFixture.systemAllowed = false
            try await collection.record()
            try await wait { collection.recordFailed && collection.captures.isEmpty }
            let after = try folders(root)
            try require(after == before,"No samples means no new Library folder")
            report["nothingStartedLeavesNoLibraryEntry"] = true
            stage = "failed System input retains microphone and permission description"
            CaptureFixture.microphoneAllowed = true
            try await collection.record()
            try await wait { collection.first?.snapshot.manifest.tracks.contains { $0.kind == "microphone" && $0.frames > 0 } == true }
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
