// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import CassiniLibrary
import CassiniTranscription
import CassiniWhistle
import Observation

private final class OffMainModelBox: @unchecked Sendable {
    var value: SpeechModelController.JobModel?
    init(_ value: SpeechModelController.JobModel?) { self.value = value }
}

/// One bounded worker, FIFO by arrival. A capture and playback may continue while
/// this child writes only app-owned sidecars. Failed jobs require an explicit retry.
@MainActor @Observable final class TranscriptionQueue {
    static let shared = TranscriptionQueue()
    static let transcriptionModePreference = "CassiniTranscriptionMode"
    private typealias WarmWorkerLease = WarmWorkerCoordinator<WarmSpeechWorker, SpeechModelController.JobModel?>.Lease
    init() {
        warmCoordinator.onFollowingChanged = { [weak self] folder in
            self?.following = folder
        }
    }
    var transcriptionMode: TranscriptionMode {
        get { TranscriptionMode.resolve(RecordingPreferences.defaults.object(forKey: Self.transcriptionModePreference)).mode }
        set {
            RecordingPreferences.defaults.set(newValue.rawValue, forKey: Self.transcriptionModePreference)
            if newValue != .transcribeWhileRecording {
                preemptFollower()
            }
        }
    }
    private(set) var active: URL?
    private(set) var activeModel: String?
    private(set) var following: URL?
    private(set) var queuedFolders = Set<String>()
    private(set) var stoppingFolders = Set<String>()
    func isQueuedOrActive(_ folder: URL) -> Bool {
        let path = folder.path
        return !stoppingFolders.contains(path) && (active?.path == path || queuedFolders.contains(path))
    }
    @ObservationIgnored private var stoppingTasks: [String:Task<Void,Never>] = [:]
    @ObservationIgnored private var pending: [LibraryMeeting] = []
    @ObservationIgnored private var automaticPending = Set<String>()
    @ObservationIgnored private var explicitRetries = Set<String>()
    @ObservationIgnored private var known = Set<String>()
    @ObservationIgnored private var userStoppedRevisions: [String:Int64] = [:]
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var preparation: Task<Void,Never>?
    private var preparing: (folder: URL, work: Task<Void,Error>)?
    @ObservationIgnored private var prepared = Set<String>()
    @ObservationIgnored private var schedulingFailures = Set<String>()
    @ObservationIgnored private var closing = false
    @ObservationIgnored private var paused = false
    @ObservationIgnored private var trashing = Set<String>()
    @ObservationIgnored private let warmCoordinator = WarmWorkerCoordinator<WarmSpeechWorker, SpeechModelController.JobModel?>()
    @ObservationIgnored private var activeRecordingFolder: URL?
    func isStopping(_ folder: URL) -> Bool { stoppingFolders.contains(folder.path) }
    func preemptFollowerForModelChange() {
        preemptFollower()
    }
    private func preemptFollower() {
        warmCoordinator.preempt()
    }
    private func terminateWarmWorkerAndWait() async {
        await warmCoordinator.terminateAndWait()
    }
    private func waitForWorkerTeardown() async {
        await warmCoordinator.waitForTeardown()
    }
    private func ensureFollowing(folder: URL) {
        let path = folder.path
        let canContinue: @MainActor () -> Bool = { [weak self] in
            guard let self else { return false }
            return self.transcriptionMode == .transcribeWhileRecording &&
                !self.closing && !self.paused && self.task == nil && self.pending.isEmpty &&
                !self.trashing.contains(path) && !self.stoppingFolders.contains(path)
        }
        warmCoordinator.ensureFollowing(folder: folder, canContinue: canContinue) { [weak self] _ in
            guard self != nil else { return nil }
            var model: SpeechModelController.JobModel?
            func takeModel() -> SpeechModelController.JobModel? {
                defer { model = nil }
                return model
            }
            func releaseModelOffMain(_ released: consuming SpeechModelController.JobModel?) async {
                let box = OffMainModelBox(consume released)
                guard box.value != nil else { return }
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    Thread.detachNewThread {
                        box.value = nil
                        continuation.resume()
                    }
                }
            }
            do {
                model = try await SpeechModelController.shared.modelForNewJob()
                guard !Task.isCancelled, canContinue() else {
                    await releaseModelOffMain(takeModel())
                    return nil
                }
                let engine = model == nil ? "whistle" : "parakeet"
                let executable = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/" + (model == nil ? "cassini-whistle-worker" : "cassini-parakeet-worker"))
                let arguments: [String] = model.map { ["--model", $0.lease.directory.path] } ?? []
                struct FollowRequest: Encodable { let id: String; let action: String; let meeting: String }
                let requestData = try JSONEncoder().encode(FollowRequest(id: UUID().uuidString, action: "follow", meeting: path))
                let worker = try await Task.detached(priority: .utility) {
                    try WarmSpeechWorker(executable: executable, arguments: arguments, environment: WhistleEnvironment.worker())
                }.value
                if Task.isCancelled || !canContinue() {
                    await worker.terminateImmediatelyAsync(releasing: takeModel())
                    return nil
                }
                let reply: WarmSpeechWorker.Reply
                do {
                    reply = try await worker.send(requestData, timeout: 60)
                } catch {
                    await worker.terminateImmediatelyAsync(releasing: takeModel())
                    return nil
                }
                struct FollowResponse: Decodable { let error: String?; let code: String? }
                let decoded = try? JSONDecoder().decode(FollowResponse.self, from: reply.line)
                if let generation = model?.generation, reply.exited, decoded?.code == "invalid-model" {
                    await worker.terminateImmediatelyAsync(releasing: takeModel())
                    await SpeechModelController.shared.invalidModel(generation: generation)
                    guard !Task.isCancelled, canContinue() else { return nil }
                    let whistleExe = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/cassini-whistle-worker")
                    let whistleWorker = try await Task.detached(priority: .utility) {
                        try WarmSpeechWorker(executable: whistleExe, arguments: [], environment: WhistleEnvironment.worker())
                    }.value
                    if Task.isCancelled || !canContinue() {
                        await whistleWorker.terminateImmediatelyAsync()
                        return nil
                    }
                    let whistleReply: WarmSpeechWorker.Reply
                    do {
                        whistleReply = try await whistleWorker.send(requestData, timeout: 60)
                    } catch {
                        await whistleWorker.terminateImmediatelyAsync()
                        return nil
                    }
                    let whistleDecoded = try? JSONDecoder().decode(FollowResponse.self, from: whistleReply.line)
                    guard !whistleReply.exited, whistleDecoded?.error == nil,
                          !Task.isCancelled, canContinue() else {
                        await whistleWorker.terminateImmediatelyAsync()
                        return nil
                    }
                    return WarmWorkerLease(worker: whistleWorker, engine: "whistle", token: nil, followingFolder: folder)
                }
                guard !reply.exited, decoded?.error == nil,
                      !Task.isCancelled, canContinue() else {
                    await worker.terminateImmediatelyAsync(releasing: takeModel())
                    return nil
                }
                return WarmWorkerLease(worker: worker, engine: engine, token: takeModel(), followingFolder: folder)
            } catch {
                await releaseModelOffMain(takeModel())
                return nil
            }
        }
    }
    @discardableResult
    func stop(_ meeting: LibraryMeeting) -> Task<Void, Never>? {
        let path = meeting.folder.path, id = meeting.id, folder = meeting.folder
        guard !closing, !trashing.contains(path), !stoppingFolders.contains(path), !meeting.metadataReadOnly else { return nil }
        stoppingFolders.insert(path)
        queuedFolders.remove(path)
        pending.removeAll { $0.folder.path == path }; prepared.remove(path)
        automaticPending.remove(path); explicitRetries.remove(path)
        let child = active?.path == path ? task : nil
        child?.cancel()
        if following?.path == path || warmCoordinator.activeLease?.followingFolder.path == path {
            preemptFollower()
        }
        let metadata = preparing?.folder.path == path ? preparing?.work : nil
        #if DEBUG
        let willWrite = fixtureOnStopMetadataWillWrite
        #endif
        let stopTask = Task {
            await waitForWorkerTeardown()
            _ = try? await metadata?.value
            await child?.value
            pending.removeAll { $0.folder.path == path }; prepared.remove(path)
            automaticPending.remove(path); explicitRetries.remove(path)
            do {
                let revision = try await Task.detached(priority:.userInitiated) {
                    #if DEBUG
                    willWrite?(folder)
                    #endif
                    return try MeetingTranscriber.stopForUser(directory:folder,id:id)
                }.value
                if let revision { userStoppedRevisions[path] = revision }
            } catch {
                if !closing, !trashing.contains(path) { NSApp.presentError(error) }
            }
            known.remove(path); schedulingFailures.remove(path)
            stoppingFolders.remove(path); stoppingTasks.removeValue(forKey:path)
            if !closing, !paused, !trashing.contains(path) {
                LibraryStore.shared.refresh(affected:folder)
            }
        }
        stoppingTasks[path] = stopTask
        return stopTask
    }
    func cancel(meeting folder: URL) async {
        let path = folder.path
        trashing.insert(path)
        queuedFolders.remove(path)
        pending.removeAll { $0.folder.path == path }; prepared.remove(path)
        automaticPending.remove(path); explicitRetries.remove(path)
        let child = active?.path == path ? task : nil
        child?.cancel()
        if following?.path == path || warmCoordinator.activeLease?.followingFolder.path == path {
            preemptFollower()
        }
        await waitForWorkerTeardown()
        let metadata = preparing?.folder.path == path ? preparing?.work : nil
        let stopping = stoppingTasks[path]
        _ = try? await metadata?.value
        await child?.value
        #if DEBUG
        if stopping != nil { fixtureOnBarrierAwaitingStops?("trash") }
        #endif
        await stopping?.value
        pending.removeAll { $0.folder.path == path }; prepared.remove(path)
        automaticPending.remove(path); explicitRetries.remove(path)
    }
    func releaseTrashed(_ folder: URL) {
        trashing.remove(folder.path); known.remove(folder.path); schedulingFailures.remove(folder.path)
        automaticPending.remove(folder.path); explicitRetries.remove(folder.path)
        userStoppedRevisions.removeValue(forKey:folder.path)
    }
    var isBusy: Bool { task != nil || preparation != nil || !pending.isEmpty || !stoppingFolders.isEmpty || !stoppingTasks.isEmpty }
    func beginShutdown() {
        guard !closing else { return }; closing = true
        preemptFollower()
        task?.cancel(); preparePending()
    }
    func waitForShutdown() async {
        await terminateWarmWorkerAndWait()
        await preparation?.value
        pending.removeAll(); prepared.removeAll(); queuedFolders.removeAll()
        automaticPending.removeAll(); explicitRetries.removeAll()
        await task?.value
        await waitForWorkerTeardown()
        #if DEBUG
        if !stoppingTasks.isEmpty { fixtureOnBarrierAwaitingStops?("shutdown") }
        #endif
        while let next = stoppingTasks.values.first {
            await next.value
        }
        await waitForWorkerTeardown()
    }
    #if DEBUG
    nonisolated enum AttemptOutcome: Equatable, Sendable { case completed, lockContended, alreadySettled, failed, cancelled }
    var preparingFixtureFolder: URL? { RecordingFixture.enabled ? preparing?.folder : nil }
    func containsPendingForTesting(_ folder: URL) -> Bool { pending.contains { $0.folder.path == folder.path } }
    func waitForFixturePreparation() async {
        precondition(RecordingFixture.enabled)
        await preparation?.value
    }
    @ObservationIgnored private var failedFixtureOnce = false
    @ObservationIgnored var fixtureAcceptance: ((URL,String) async -> Void)?
    @ObservationIgnored var fixtureCompletion: ((URL,String,Bool) -> Void)?
    @ObservationIgnored var fixturePreparationStarted: ((URL) -> Void)?
    @ObservationIgnored var fixtureOnAttemptOutcome: ((URL,AttemptOutcome) -> Void)?
    @ObservationIgnored var fixtureOnStopMetadataWillWrite: (@Sendable (URL) -> Void)?
    @ObservationIgnored var fixtureOnBarrierAwaitingStops: ((String) -> Void)?
    #endif
    // Persist accepted queue intent before any inactive folder can move.
    // The active child's paths remain protected; queued folders are rediscovered.
    func pauseForMove() async {
        paused = true
        await terminateWarmWorkerAndWait()
        await preparation?.value
        pending.removeAll(); prepared.removeAll(); queuedFolders.removeAll()
        automaticPending.removeAll(); explicitRetries.removeAll()
        #if DEBUG
        if !stoppingTasks.isEmpty { fixtureOnBarrierAwaitingStops?("move") }
        #endif
        while let next = stoppingTasks.values.first {
            await next.value
        }
        await waitForWorkerTeardown()
    }
    func resumeAfterMove() { guard !closing else { return }; paused = false; known = Set(active.map { [$0.path] } ?? []) }
    func consider(_ meetings: [LibraryMeeting], automatic: Bool) {
        guard automatic, !closing, !paused else { return }
        let mode = transcriptionMode
        let recordingMeeting = meetings.first {
            $0.state.lifecycle == .recording && !trashing.contains($0.folder.path) && !stoppingFolders.contains($0.folder.path)
        }
        activeRecordingFolder = recordingMeeting?.folder
        let byPath = Dictionary(uniqueKeysWithValues:meetings.map { ($0.folder.path,$0) })
        pending.removeAll { queued in
            let path = queued.folder.path
            guard automaticPending.contains(path), preparing?.folder.path != path,
                  let current = byPath[path], !current.canQueueAutomatically else { return false }
            queuedFolders.remove(path)
            prepared.remove(path); known.remove(path); automaticPending.remove(path); explicitRetries.remove(path)
            return true
        }
        let unsettled = Set(meetings.filter { [.none,.queued,.running].contains($0.state.transcript) }.map(\.folder.path))
        known.formIntersection(unsettled.union(pending.map(\.folder.path)).union(active.map { [$0.path] } ?? []))
        for meeting in meetings where userStoppedRevisions[meeting.folder.path] != nil {
            if meeting.transcriptPaused || ![.queued,.running].contains(meeting.state.transcript),
               let stopped = userStoppedRevisions[meeting.folder.path], (meeting.metadataRevision ?? -1) >= stopped {
                userStoppedRevisions.removeValue(forKey:meeting.folder.path)
            }
        }
        let candidates = meetings.filter(\.canQueueAutomatically)
            .sorted { ($0.timeSortKey ?? "") < ($1.timeSortKey ?? "") }
        for meeting in candidates where !schedulingFailures.contains(meeting.folder.path) {
            if mode == .recordOnly, meeting.state.transcript == .none { continue }
            if let stopped = userStoppedRevisions[meeting.folder.path], (meeting.metadataRevision ?? -1) <= stopped { continue }
            enqueue(meeting, automatic: true)
        }
        if mode == .transcribeWhileRecording {
            if task == nil, pending.isEmpty, let recording = recordingMeeting {
                ensureFollowing(folder: recording.folder)
            } else if recordingMeeting == nil, task == nil, pending.isEmpty, warmCoordinator.activeLease != nil {
                preemptFollower()
            }
        } else if warmCoordinator.hasActiveOrStartingWorker {
            preemptFollower()
        }
    }
    func enqueue(_ meeting: LibraryMeeting, retry: Bool = false, automatic: Bool = false) {
        let path = meeting.folder.path
        guard !closing, !paused, !trashing.contains(path), !stoppingFolders.contains(path),
              !meeting.metadataReadOnly, meeting.state.lifecycle == .saved, !meeting.audioFiles.isEmpty,
              active?.path != path else { return }
        if let existingIndex = pending.firstIndex(where: { $0.folder.path == path }) {
            if !automatic {
                automaticPending.remove(path)
                if retry { explicitRetries.insert(path) }
                pending[existingIndex] = meeting
            }
            return
        }
        if !automatic {
            userStoppedRevisions.removeValue(forKey:path)
            if retry || meeting.transcriptPaused { known.remove(path) }
            if following?.path != path, warmCoordinator.activeLease?.followingFolder.path != path {
                preemptFollower()
            }
        } else if retry {
            known.remove(path)
        }
        guard known.insert(path).inserted else { return }
        schedulingFailures.remove(path)
        if automatic { automaticPending.insert(path); explicitRetries.remove(path) }
        else { automaticPending.remove(path); if retry { explicitRetries.insert(path) } else { explicitRetries.remove(path) } }
        queuedFolders.insert(path)
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
                let path = meeting.folder.path
                let isAutomatic = automaticPending.contains(path)
                let isExplicitRetry = explicitRetries.contains(path)
                do {
                    defer { preparing = nil }
                    var stillEligible = true
                    if ![.queued,.running].contains(meeting.state.transcript) || isExplicitRetry {
                        let work = Task.detached(priority:.userInitiated) {
                            guard try MeetingTranscriber.queueIfEligible(directory:meeting.folder,id:meeting.id,automatic:isAutomatic,explicitRetry:isExplicitRetry) else {
                                throw CancellationError()
                            }
                        }
                        preparing = (meeting.folder,work)
                        #if DEBUG
                        if RecordingFixture.enabled { fixturePreparationStarted?(meeting.folder) }
                        #endif
                        do {
                            try await work.value
                        } catch is CancellationError {
                            stillEligible = false
                        }
                    }
                    if !stillEligible {
                        queuedFolders.remove(path)
                        pending.removeAll { $0.folder.path == path }; known.remove(path)
                        automaticPending.remove(path); explicitRetries.remove(path)
                        startNext()
                    } else if !trashing.contains(path), !stoppingFolders.contains(path), pending.contains(where:{ $0.folder == meeting.folder }) {
                        prepared.insert(path); startNext()
                    }
                } catch {
                    queuedFolders.remove(path)
                    pending.removeAll { $0.folder.path == path }; known.remove(path)
                    automaticPending.remove(path); explicitRetries.remove(path)
                    schedulingFailures.insert(path)
                    if !closing, !trashing.contains(path) { NSApp.presentError(error) }; startNext()
                }
            }
        }
    }
    private func startNext() {
        guard !closing, !paused, task == nil, !pending.isEmpty else { return }
        let nextPath = pending[0].folder.path
        guard prepared.contains(nextPath) else { return }
        let meeting = pending.removeFirst(); active = meeting.folder
        queuedFolders.remove(nextPath)
        prepared.remove(nextPath); automaticPending.remove(nextPath); explicitRetries.remove(nextPath)
        task = Task {
            var completedSuccessfully = false
            var retryDeferred = false
            var alreadySettled = false
            #if DEBUG
            var debugOutcome: AttemptOutcome = .failed
            #endif
            do {
                let precheck = try await Task.detached(priority:.userInitiated) {
                    try MeetingTranscriber.precheckAttempt(directory:meeting.folder)
                }.value
                try Task.checkCancellation()
                switch precheck {
                case .lockContended:
                    retryDeferred = true
                    #if DEBUG
                    debugOutcome = .lockContended
                    #endif
                case .alreadySettled:
                    alreadySettled = true
                    #if DEBUG
                    debugOutcome = .alreadySettled
                    #endif
                case .eligible:
                    struct Request: Encodable { let id: String; let action: String; let meeting: String; let me: String; let others: String; let uiLanguage: String }
                    let input = try JSONEncoder().encode(Request(id: UUID().uuidString, action: "transcribeMeeting", meeting: meeting.folder.path, me: UXText.text("common.me"), others: UXText.text("common.theOthers"), uiLanguage: UXText.language.rawValue)) + Data([10])
                    let desiredEngine = SpeechModelController.shared.usesParakeet && SpeechModelController.shared.downloaded ? "parakeet" : "whistle"
                    var fixtureOverridesWorker = false
                    #if DEBUG
                    if RecordingFixture.transcribes,
                       (LibraryLaunchContext.argument("-CassiniFailTranscriptionOnce") == "YES" && !failedFixtureOnce) ||
                       LibraryLaunchContext.argument("-CassiniSlowTranscription") == "YES" {
                        fixtureOverridesWorker = true
                    }
                    #endif
                    // Warm handoff: if our single warm worker is already following this exact meeting
                    // with the desired engine, dispatch `transcribeMeeting` onto that same worker.
                    let handedOffWarm: WarmWorkerLease?
                    if !fixtureOverridesWorker,
                       let lease = warmCoordinator.claimForHandoff(folder: meeting.folder, desiredEngine: desiredEngine) {
                        handedOffWarm = lease
                    } else {
                        handedOffWarm = nil
                        await terminateWarmWorkerAndWait()
                        try Task.checkCancellation()
                    }
                    struct Response: Decodable { let error: String?; let code: String? }
                    if let warm = handedOffWarm {
                        defer {
                            warmCoordinator.releaseHandedOff(warm, graceful: true)
                        }
                        activeModel = warm.engine
                        #if DEBUG
                        if SettingsFixture.id != nil, let acceptance = fixtureAcceptance {
                            await acceptance(meeting.folder, activeModel ?? "")
                        }
                        #endif
                        let reply = try await warm.worker.send(input, timeout: 24 * 60 * 60)
                        let response = try? JSONDecoder().decode(Response.self, from: reply.line)
                        if let model = warm.token, reply.exited, response?.code == "invalid-model" {
                            await SpeechModelController.shared.invalidModel(generation: model.generation)
                            try Task.checkCancellation(); activeModel = "whistle"
                            let whistleWorker = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/cassini-whistle-worker")
                            let fallbackResult = try await WhistleSubprocess.run(executable: whistleWorker, arguments: [], environment: WhistleEnvironment.worker(), input: input, timeout: 24 * 60 * 60)
                            guard fallbackResult.status == 0, fallbackResult.inputError == nil else { throw TranscriptionFailure.runtime("worker exited") }
                            let fallbackResponse = try JSONDecoder().decode(Response.self, from: fallbackResult.stdout)
                            if let error = fallbackResponse.error {
                                if error.contains("meeting is already being written down") {
                                    retryDeferred = true
                                    #if DEBUG
                                    debugOutcome = .lockContended
                                    #endif
                                } else {
                                    throw TranscriptionFailure.runtime(error)
                                }
                            } else {
                                completedSuccessfully = true
                                #if DEBUG
                                debugOutcome = .completed
                                #endif
                            }
                        } else {
                            guard (!reply.exited || reply.status == 0), let response else { throw TranscriptionFailure.runtime("worker exited") }
                            if let error = response.error {
                                if error.contains("meeting is already being written down") {
                                    retryDeferred = true
                                    #if DEBUG
                                    debugOutcome = .lockContended
                                    #endif
                                } else {
                                    throw TranscriptionFailure.runtime(error)
                                }
                            } else {
                                completedSuccessfully = true
                                #if DEBUG
                                debugOutcome = .completed
                                #endif
                            }
                        }
                        SpeechModelController.shared.transcriptionFinished(engine: activeModel ?? "", succeeded: completedSuccessfully)
                    } else {
                        let model = try await SpeechModelController.shared.modelForNewJob()
                        defer { withExtendedLifetime(model) {} }
                        var worker = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/" + (model == nil ? "cassini-whistle-worker" : "cassini-parakeet-worker"))
                        var arguments: [String] = model.map { ["--model",$0.lease.directory.path] } ?? []
                        activeModel = model == nil ? "whistle" : "parakeet"
                        #if DEBUG
                        if SettingsFixture.id != nil, let acceptance = fixtureAcceptance {
                            await acceptance(meeting.folder,activeModel ?? "")
                        }
                        if RecordingFixture.transcribes, LibraryLaunchContext.argument("-CassiniFailTranscriptionOnce") == "YES", !failedFixtureOnce {
                            failedFixtureOnce = true; worker = URL(fileURLWithPath: "/usr/bin/false")
                        }
                        if RecordingFixture.transcribes, LibraryLaunchContext.argument("-CassiniSlowTranscription") == "YES" {
                            worker = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/cassini-whistle-worker")
                            arguments = ["--fixture-wait-for-cancellation"]
                        }
                        #endif
                        var result = try await WhistleSubprocess.run(executable: worker, arguments: arguments, environment: WhistleEnvironment.worker(), input: input, timeout: 24 * 60 * 60)
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
                        if let error = response.error {
                            if error.contains("meeting is already being written down") {
                                retryDeferred = true
                                #if DEBUG
                                debugOutcome = .lockContended
                                #endif
                            } else {
                                throw TranscriptionFailure.runtime(error)
                            }
                        } else {
                            completedSuccessfully = true
                            #if DEBUG
                            debugOutcome = .completed
                            #endif
                        }
                        SpeechModelController.shared.transcriptionFinished(engine:activeModel ?? "",succeeded:completedSuccessfully)
                    }
                }
            } catch is CancellationError {
                #if DEBUG
                debugOutcome = .cancelled
                #endif
                // Quit pauses work. Preserve the sidecar and its reference for
                // next-launch recovery instead of turning cancellation into failure.
                if !stoppingFolders.contains(meeting.folder.path), !trashing.contains(meeting.folder.path) {
                    try? await Task.detached(priority:.userInitiated) {
                        try MeetingTranscriber.pauseForResume(directory:meeting.folder,id:meeting.id)
                    }.value
                    if !closing { retryDeferred = true }
                }
            } catch {
                // Worker crashes and bundle/decoder failures take the retry path only when
                // no other process holds `.transcription.lock` or already settled this meeting.
                let disposition = (try? await Task.detached(priority:.userInitiated) {
                    try MeetingTranscriber.failAttemptIfOwnedAndUnsettled(directory:meeting.folder,id:meeting.id)
                }.value) ?? .eligible
                switch disposition {
                case .lockContended:
                    retryDeferred = true
                    #if DEBUG
                    debugOutcome = .lockContended
                    #endif
                case .alreadySettled:
                    alreadySettled = true
                    #if DEBUG
                    debugOutcome = .alreadySettled
                    #endif
                case .eligible:
                    #if DEBUG
                    debugOutcome = .failed
                    #endif
                }
            }
            if !alreadySettled && !retryDeferred {
                await Task.detached { SegmentedAudio.removeAbandonedScratch() }.value
            }
            let finishedModel = activeModel ?? ""
            active = nil; activeModel = nil; task = nil
            if retryDeferred || alreadySettled { known.remove(meeting.folder.path) }
            startNext()
            if task == nil, pending.isEmpty, transcriptionMode == .transcribeWhileRecording, let recording = activeRecordingFolder {
                ensureFollowing(folder: recording)
            }
            if alreadySettled, !closing, !paused, !trashing.contains(meeting.folder.path), !stoppingFolders.contains(meeting.folder.path) {
                LibraryStore.shared.refresh(affected:meeting.folder)
            } else if retryDeferred, !closing, !trashing.contains(meeting.folder.path), !stoppingFolders.contains(meeting.folder.path) {
                let folder = meeting.folder
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for:.milliseconds(300))
                    guard let self, !self.closing, !self.paused,
                          !self.trashing.contains(folder.path), !self.stoppingFolders.contains(folder.path) else { return }
                    LibraryStore.shared.refresh(affected:folder)
                }
            }
            #if DEBUG
            fixtureOnAttemptOutcome?(meeting.folder,debugOutcome)
            if SettingsFixture.id != nil, !alreadySettled, !retryDeferred {
                fixtureCompletion?(meeting.folder,finishedModel,completedSuccessfully)
            }
            #endif
        }
    }
}

