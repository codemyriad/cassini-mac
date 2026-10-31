// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import CassiniLibrary
import CassiniTranscription
import CassiniWhistle
import Observation
#if DEBUG
import CassiniRecording
import CassiniKit
import Darwin
#endif

/// One bounded worker, FIFO by arrival. A capture and playback may continue while
/// this child writes only app-owned sidecars. Failed jobs require an explicit retry.
@MainActor @Observable final class TranscriptionQueue {
    static let shared = TranscriptionQueue()
    private(set) var active: URL?
    private(set) var activeModel: String?
    @ObservationIgnored private var pending: [LibraryMeeting] = []
    @ObservationIgnored private var echoPending: [LibraryMeeting] = []
    @ObservationIgnored private var echoKnown = Set<String>()
    @ObservationIgnored private var echoActive = false
    @ObservationIgnored private var known = Set<String>()
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var preparation: Task<Void,Never>?
    @ObservationIgnored private var preparing: (folder: URL, work: Task<Void,Error>)?
    @ObservationIgnored private var prepared = Set<String>()
    @ObservationIgnored private var schedulingFailures = Set<String>()
    @ObservationIgnored private var closing = false
    @ObservationIgnored private var paused = false
    @ObservationIgnored private var trashing = Set<String>()
    func cancel(meeting folder: URL) async {
        let path = folder.path
        trashing.insert(path)
        pending.removeAll { $0.folder.path == path }; prepared.remove(path)
        echoPending.removeAll { $0.folder.path == path }; echoKnown.remove(path)
        let child = active?.path == path ? task : nil
        child?.cancel()
        let metadata = preparing?.folder.path == path ? preparing?.work : nil
        _ = try? await metadata?.value
        await child?.value
        pending.removeAll { $0.folder.path == path }; prepared.remove(path)
        echoPending.removeAll { $0.folder.path == path }; echoKnown.remove(path)
    }
    func releaseTrashed(_ folder: URL) {
        trashing.remove(folder.path); known.remove(folder.path); echoKnown.remove(folder.path); schedulingFailures.remove(folder.path)
    }
    var isBusy: Bool { task != nil || preparation != nil || !pending.isEmpty }
    func beginShutdown() {
        guard !closing else { return }; closing = true; echoPending.removeAll()
        task?.cancel(); preparePending()
    }
    func waitForShutdown() async {
        await preparation?.value
        pending.removeAll(); prepared.removeAll()
        await task?.value
    }
    #if DEBUG
    var preparingFixtureFolder: URL? { RecordingFixture.enabled ? preparing?.folder : nil }
    var classifyingEchoFixture: Bool { RecordingFixture.enabled && echoActive }
    @ObservationIgnored var echoCheckpointFixture: (@Sendable () throws -> Void)?
    @ObservationIgnored private var failedFixtureOnce = false
    #endif
    // Persist accepted queue intent before any inactive folder can move.
    // The active child's paths remain protected; queued folders are rediscovered.
    func pauseForMove() async {
        paused = true; echoPending.removeAll()
        if echoActive { task?.cancel(); await task?.value }
        await preparation?.value
        pending.removeAll(); prepared.removeAll()
    }
    func resumeAfterMove() { guard !closing else { return }; paused = false; known = Set(active.map { [$0.path] } ?? []); echoKnown.removeAll() }
    func consider(_ meetings: [LibraryMeeting], automatic: Bool) {
        guard automatic, !closing, !paused else { return }
        known.formIntersection(Set(meetings.map { $0.folder.path }).union(pending.map { $0.folder.path }).union(active.map { [$0.path] } ?? []))
        let candidates = meetings.filter(\.canQueueAutomatically)
            .sorted { ($0.start ?? .distantPast) < ($1.start ?? .distantPast) }
        for meeting in candidates where !schedulingFailures.contains(meeting.folder.path) { enqueue(meeting) }
    }
    func considerExistingEcho(_ meetings: [LibraryMeeting], enabled: Bool) {
        guard enabled, !closing, !paused else { return }
        let present = Set(meetings.map { $0.folder.path })
        echoPending.removeAll { !present.contains($0.folder.path) }
        echoKnown.formIntersection(present.union(active.map { [$0.path] } ?? []))
        for meeting in meetings where ExistingTranscriptEcho.candidate(meeting) && !trashing.contains(meeting.folder.path) {
            if echoKnown.insert(meeting.folder.path).inserted { echoPending.append(meeting) }
        }
        startNextEcho()
    }
    func enqueue(_ meeting: LibraryMeeting, retry: Bool = false) {
        guard !closing, !paused, !trashing.contains(meeting.folder.path), !meeting.metadataReadOnly, meeting.state.lifecycle == .saved, !meeting.audioFiles.isEmpty,
              active?.path != meeting.folder.path, !pending.contains(where: { $0.folder.path == meeting.folder.path }) else { return }
        if retry { known.remove(meeting.folder.path) }
        guard known.insert(meeting.folder.path).inserted else { return }
        schedulingFailures.remove(meeting.folder.path)
        pending.append(meeting); preparePending()
    }
    func writeDown(_ detail: MeetingDetailModel) {
        guard !closing, !paused, detail.meeting.canWriteDown else { return }
        guard let original = detail.fileURL else { enqueue(detail.meeting, retry: detail.meeting.state.transcript == .failed || detail.meeting.hasNoSpeech); return }
        LibraryImportCoordinator.shared.open(original,writingDown:true,retaining:detail)
    }
    private func preparePending() {
        guard preparation == nil else { return }
        preparation = Task {
            defer { preparation = nil }
            while let meeting = pending.first(where:{ !prepared.contains($0.folder.path) }) {
                do {
                    defer { preparing = nil }
                    if ![.queued,.running].contains(meeting.state.transcript) {
                        let work = Task.detached(priority:.userInitiated) {
                            try MeetingTranscriber.setStatus(directory:meeting.folder,id:meeting.id,status:"queued")
                        }
                        preparing = (meeting.folder,work)
                        try await work.value
                    }
                    if !trashing.contains(meeting.folder.path), pending.contains(where:{ $0.folder == meeting.folder }) {
                        prepared.insert(meeting.folder.path); startNext()
                    }
                } catch {
                    pending.removeAll { $0.folder.path == meeting.folder.path }; known.remove(meeting.folder.path)
                    schedulingFailures.insert(meeting.folder.path)
                    if !closing, !trashing.contains(meeting.folder.path) { NSApp.presentError(error) }; startNext()
                }
            }
        }
    }
    func pauseEchoForRecording() async {
        guard echoActive else { return }
        task?.cancel(); await task?.value
    }
    private func startNextEcho() {
        guard !closing, !paused, task == nil, preparation == nil, pending.isEmpty, !echoPending.isEmpty,
              !RecordingOverview.active, !RecordingOverview.starting, !RecordingOverview.saving,
              CaptureActivityStore.shared.snapshot().isEmpty else { return }
        let meeting = echoPending.removeFirst()
        guard !trashing.contains(meeting.folder.path) else { startNextEcho(); return }
        active = meeting.folder; activeModel = nil; echoActive = true
        task = Task {
            var changed = false
            do {
                #if DEBUG
                let fixture = RecordingFixture.enabled ? echoCheckpointFixture : nil
                #endif
                let work = Task.detached(priority:.background) {
                    try ExistingTranscriptEcho.run(directory:meeting.folder,checkpoint:{
                        #if DEBUG
                        try fixture?()
                        #endif
                        try Task.checkCancellation()
                        if !CaptureActivityStore.shared.snapshot().isEmpty { throw CancellationError() }
                    },commit:CaptureActivityStore.shared.commitWhileIdle)
                }
                let result = try await withTaskCancellationHandler(operation:{ try await work.value },onCancel:{ work.cancel() })
                switch result {
                case .classified: changed = true
                case .changed: echoKnown.remove(meeting.folder.path)
                case .alreadyComplete, .ineligible: break
                }
            } catch is CancellationError { echoKnown.remove(meeting.folder.path) }
            catch { /* Leave unsupported/missing/changed inputs untouched; retry on next launch. */ }
            active = nil; echoActive = false; task = nil
            if changed { LibraryStore.shared.refresh(affected:meeting.folder) }
            startNext()
        }
    }
    private func startNext() {
        guard !closing, !paused, task == nil else { return }
        guard !pending.isEmpty else { startNextEcho(); return }
        guard prepared.contains(pending[0].folder.path) else { return }
        let meeting = pending.removeFirst(); active = meeting.folder
        prepared.remove(meeting.folder.path)
        task = Task {
            do {
                struct Request: Encodable { let id: String; let meeting: String; let me: String; let others: String }
                let input = try JSONEncoder().encode(Request(id: UUID().uuidString, meeting: meeting.folder.path, me: UXText.text("common.me"), others: UXText.text("common.theOthers"))) + Data([10])
                let model = try await SpeechModelController.shared.modelForNewJob()
                defer { withExtendedLifetime(model) {} }
                var worker = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/" + (model == nil ? "cassini-whistle-worker" : "cassini-parakeet-worker"))
                var arguments: [String] = model.map { ["--model",$0.lease.directory.path] } ?? []
                activeModel = model == nil ? "whistle" : "parakeet"
                #if DEBUG
                if RecordingFixture.transcribes, LibraryLaunchContext.argument("-CassiniFailTranscriptionOnce") == "YES", !failedFixtureOnce {
                    failedFixtureOnce = true; worker = URL(fileURLWithPath: "/usr/bin/false")
                }
                if RecordingFixture.transcribes, LibraryLaunchContext.argument("-CassiniSlowTranscription") == "YES" {
                    worker = URL(fileURLWithPath:"/bin/sleep"); arguments = ["60"]
                }
                #endif
                var result = try await WhistleSubprocess.run(executable: worker, arguments: arguments, environment: WhistleEnvironment.worker(), input: input, timeout: 24 * 60 * 60)
                struct Response: Decodable { let error: String?; let code: String? }
                // Startup model checks fail before the Parakeet worker can read
                // or edit the meeting. Inspect the structured error even on a
                // nonzero exit, reset the choice, then retry this job in Whistle.
                if let model, result.status != 0,
                   (try? JSONDecoder().decode(Response.self,from:result.stdout).code) == "invalid-model" {
                    await SpeechModelController.shared.invalidModel(generation:model.generation)
                    try Task.checkCancellation(); activeModel = "whistle"
                    worker = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/cassini-whistle-worker")
                    result = try await WhistleSubprocess.run(executable:worker,arguments:[],environment:WhistleEnvironment.worker(),input:input,timeout:24 * 60 * 60)
                }
                guard result.status == 0, result.inputError == nil else { throw TranscriptionFailure.runtime("worker exited") }
                let response = try JSONDecoder().decode(Response.self, from: result.stdout)
                if let error = response.error, !error.contains("meeting is already being written down") { throw TranscriptionFailure.runtime(error) }
            } catch is CancellationError {
                // Quit pauses work. Preserve the sidecar and its reference for
                // next-launch recovery instead of turning cancellation into failure.
                try? await Task.detached(priority:.userInitiated) {
                    try MeetingTranscriber.pauseForResume(directory:meeting.folder,id:meeting.id)
                }.value
            } catch {
                // Worker crashes and bundle/decoder failures take the same retry path.
                try? await Task.detached(priority:.userInitiated) {
                    try MeetingTranscriber.setStatus(directory:meeting.folder,id:meeting.id,status:"failed")
                }.value
            }
            await Task.detached { SegmentedAudio.removeAbandonedScratch() }.value
            active = nil; activeModel = nil; task = nil; startNext()
        }
    }
}

#if DEBUG
/// Private filesystem/RAM proof. The only worker is a cancellable sleep fixture.
@MainActor enum ImportLifecycleSelfTest {
    static func run() async {
        guard RecordingFixture.enabled, RecordingFixture.transcribes,
              LibraryLaunchContext.argument("-CassiniSlowTranscription") == "YES",
              let root = RecordingFixture.root else { exit(78) }
        let queue = TranscriptionQueue.shared, importer = LibraryImportCoordinator.shared
        do {
            let session = try RecordingSession(parent:root,title:"Private queue",source:"macos")
            try session.addTrack(id:"mic",label:"Mic",kind:"microphone",sampleRate:16000,channels:1)
            try session.appendNative(id:"mic",pcm:Data(repeating:0,count:3200),offsetMs:0); try session.finish()
            try MeetingMetadataWriter(directory:session.directory,id:session.manifest.id).createIfNeeded()
            let meeting = try require(LibraryScanner(root:root).scan().meetings.first)
            let fd = open(session.directory.path,O_RDONLY | O_DIRECTORY | O_CLOEXEC)
            guard fd >= 0, flock(fd,LOCK_EX | LOCK_NB) == 0 else { throw POSIXError(.EIO) }
            Thread.detachNewThread { Thread.sleep(forTimeInterval:1); flock(fd,LOCK_UN); close(fd) }
            let began = ProcessInfo.processInfo.systemUptime
            queue.enqueue(meeting)
            guard ProcessInfo.processInfo.systemUptime - began < 0.6 else { throw POSIXError(.ETIMEDOUT) }
            try await wait { queue.active != nil }
            let document = try JSONSerialization.jsonObject(with:Data(contentsOf:session.directory.appendingPathComponent("meeting.json"))) as! [String:Any]
            guard (document["transcript"] as? [String:Any])?["status"] as? String == "queued" else { throw POSIXError(.EINVAL) }
            let input = Bundle.main.resourceURL!.appendingPathComponent("Fixtures/Library/main/root/Received-a0000000-0000-4000-8000-000000000006/original.opus")
            let source = root.deletingLastPathComponent().appendingPathComponent("Private source.opus")
            _ = try OpusStreamFile.rewrite(Data(contentsOf:input),tags:PortableMeetingTags.packet(),to:source)
            let file = try CassiniReader.read(contentsOf:source)
            let detail = MeetingDetailModel(meeting:MeetingPresentation.external(file,url:source),fileURL:source,frozen:true)
            queue.writeDown(detail); queue.writeDown(detail)
            try await wait { !importer.isBusy }
            let imported = try LibraryScanner(root:root).scan().meetings.filter { $0.state.origin == .received }
            guard imported.count == 1 else { throw POSIXError(.EINVAL) }
            let received = imported[0]
            try await wait {
                (try? LibraryScanner(root:root).scan().meetings.first(where:{ $0.id == received.id })?.state.transcript) == .queued
            }
            // A second accepted import is owned by the same shutdown path.
            let another = root.deletingLastPathComponent().appendingPathComponent("Another source.opus")
            try FileManager.default.copyItem(at:source,to:another)
            let waiting = try RecordingSession(parent:root,title:"Queued before Quit",source:"macos")
            try waiting.addTrack(id:"mic",label:"Mic",kind:"microphone",sampleRate:16000,channels:1)
            try waiting.appendNative(id:"mic",pcm:Data(repeating:0,count:3200),offsetMs:0); try waiting.finish()
            try MeetingMetadataWriter(directory:waiting.directory,id:waiting.manifest.id).createIfNeeded()
            let waitingMeeting = try require(LibraryScanner(root:root).scan().meetings.first(where:{ $0.id == waiting.manifest.id }))
            let held = open(waiting.directory.path,O_RDONLY | O_DIRECTORY | O_CLOEXEC)
            guard held >= 0, flock(held,LOCK_EX | LOCK_NB) == 0 else { throw POSIXError(.EIO) }
            Thread.detachNewThread { Thread.sleep(forTimeInterval:1); flock(held,LOCK_UN); close(held) }
            queue.enqueue(waitingMeeting)
            importer.open(another)
            await Task.yield()
            importer.beginShutdown(); queue.beginShutdown()
            await importer.waitForShutdown(); await queue.waitForShutdown()
            guard !importer.isBusy, !queue.isBusy else { throw POSIXError(.EBUSY) }
            guard try LibraryScanner(root:root).scan().meetings.first(where:{ $0.id == waiting.manifest.id })?.state.transcript == .queued else { throw POSIXError(.EINVAL) }
            for name in try FileManager.default.contentsOfDirectory(atPath:root.path) where name.hasPrefix("Received-") {
                guard FileManager.default.fileExists(atPath:root.appendingPathComponent(name + "/meeting.json").path) else { throw POSIXError(.EINVAL) }
            }
            try FileManager.default.removeItem(at:root.deletingLastPathComponent())
            let report = ["queueMetadataOffMain":true,"metadataBeforeWorker":true,"repeatedWriteDownImportsOnce":true,"shutdownWaitsForImport":true,"queuedIntentSurvivesQuit":true,"audioDevicesOpened":false]
            FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject:report,options:[.sortedKeys]) + Data([10])); exit(0)
        } catch {
            importer.beginShutdown(); queue.beginShutdown(); await importer.waitForShutdown(); await queue.waitForShutdown()
            try? FileManager.default.removeItem(at:root.deletingLastPathComponent())
            FileHandle.standardError.write(Data("Import lifecycle proof failed: \(error)\n".utf8)); exit(1)
        }
    }
    private static func require<T>(_ value: T?) throws -> T { guard let value else { throw POSIXError(.EINVAL) }; return value }
    private static func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<600 { if condition() { return }; try await Task.sleep(for:.milliseconds(25)) }
        throw POSIXError(.ETIMEDOUT)
    }
}
#endif
