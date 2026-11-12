// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import CassiniLibrary
import CassiniTranscription
import CassiniWhistle
import Observation
#if DEBUG
import SwiftUI
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
    private(set) var stoppingFolders = Set<String>()
    @ObservationIgnored private var pending: [LibraryMeeting] = []
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
    func isStopping(_ folder: URL) -> Bool { stoppingFolders.contains(folder.path) }
    func stop(_ meeting: LibraryMeeting) {
        let path = meeting.folder.path, id = meeting.id, folder = meeting.folder
        guard !closing, !trashing.contains(path), !stoppingFolders.contains(path), !meeting.metadataReadOnly else { return }
        stoppingFolders.insert(path)
        pending.removeAll { $0.folder.path == path }; prepared.remove(path)
        let child = active?.path == path ? task : nil
        child?.cancel()
        let metadata = preparing?.folder.path == path ? preparing?.work : nil
        Task {
            _ = try? await metadata?.value
            await child?.value
            pending.removeAll { $0.folder.path == path }; prepared.remove(path)
            do {
                let revision = try await Task.detached(priority:.userInitiated) {
                    try MeetingTranscriber.stopForUser(directory:folder,id:id)
                }.value
                if let revision { userStoppedRevisions[path] = revision }
            } catch {
                if !closing, !trashing.contains(path) { NSApp.presentError(error) }
            }
            known.remove(path); schedulingFailures.remove(path)
            stoppingFolders.remove(path)
            LibraryStore.shared.refresh(affected:folder)
        }
    }
    func cancel(meeting folder: URL) async {
        let path = folder.path
        trashing.insert(path)
        pending.removeAll { $0.folder.path == path }; prepared.remove(path)
        let child = active?.path == path ? task : nil
        child?.cancel()
        let metadata = preparing?.folder.path == path ? preparing?.work : nil
        _ = try? await metadata?.value
        await child?.value
        pending.removeAll { $0.folder.path == path }; prepared.remove(path)
    }
    func releaseTrashed(_ folder: URL) {
        trashing.remove(folder.path); known.remove(folder.path); schedulingFailures.remove(folder.path)
        userStoppedRevisions.removeValue(forKey:folder.path)
    }
    var isBusy: Bool { task != nil || preparation != nil || !pending.isEmpty || !stoppingFolders.isEmpty }
    func beginShutdown() {
        guard !closing else { return }; closing = true
        task?.cancel(); preparePending()
    }
    func waitForShutdown() async {
        await preparation?.value
        pending.removeAll(); prepared.removeAll()
        await task?.value
    }
    #if DEBUG
    var preparingFixtureFolder: URL? { RecordingFixture.enabled ? preparing?.folder : nil }
    func waitForFixturePreparation() async {
        precondition(RecordingFixture.enabled)
        await preparation?.value
    }
    @ObservationIgnored private var failedFixtureOnce = false
    @ObservationIgnored var fixtureAcceptance: ((URL,String) async -> Void)?
    @ObservationIgnored var fixtureCompletion: ((URL,String,Bool) -> Void)?
    @ObservationIgnored var fixturePreparationStarted: ((URL) -> Void)?
    #endif
    // Persist accepted queue intent before any inactive folder can move.
    // The active child's paths remain protected; queued folders are rediscovered.
    func pauseForMove() async {
        paused = true
        await preparation?.value
        pending.removeAll(); prepared.removeAll()
    }
    func resumeAfterMove() { guard !closing else { return }; paused = false; known = Set(active.map { [$0.path] } ?? []) }
    func consider(_ meetings: [LibraryMeeting], automatic: Bool) {
        guard automatic, !closing, !paused else { return }
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
            if let stopped = userStoppedRevisions[meeting.folder.path], (meeting.metadataRevision ?? -1) <= stopped { continue }
            enqueue(meeting, automatic: true)
        }
    }
    func enqueue(_ meeting: LibraryMeeting, retry: Bool = false, automatic: Bool = false) {
        guard !closing, !paused, !trashing.contains(meeting.folder.path), !stoppingFolders.contains(meeting.folder.path),
              !meeting.metadataReadOnly, meeting.state.lifecycle == .saved, !meeting.audioFiles.isEmpty,
              active?.path != meeting.folder.path, !pending.contains(where: { $0.folder.path == meeting.folder.path }) else { return }
        if !automatic {
            userStoppedRevisions.removeValue(forKey:meeting.folder.path)
            if retry || meeting.transcriptPaused { known.remove(meeting.folder.path) }
        } else if retry {
            known.remove(meeting.folder.path)
        }
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
                        #if DEBUG
                        if RecordingFixture.enabled { fixturePreparationStarted?(meeting.folder) }
                        #endif
                        try await work.value
                    }
                    if !trashing.contains(meeting.folder.path), !stoppingFolders.contains(meeting.folder.path), pending.contains(where:{ $0.folder == meeting.folder }) {
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
    private func startNext() {
        guard !closing, !paused, task == nil, !pending.isEmpty else { return }
        guard prepared.contains(pending[0].folder.path) else { return }
        let meeting = pending.removeFirst(); active = meeting.folder
        prepared.remove(meeting.folder.path)
        task = Task {
            var completedSuccessfully = false
            var retryDeferred = false
            do {
                struct Request: Encodable { let id: String; let meeting: String; let me: String; let others: String; let uiLanguage: String }
                let input = try JSONEncoder().encode(Request(id: UUID().uuidString, meeting: meeting.folder.path, me: UXText.text("common.me"), others: UXText.text("common.theOthers"),uiLanguage:UXText.language.rawValue)) + Data([10])
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
                if let error = response.error {
                    if error.contains("meeting is already being written down") { retryDeferred = true }
                    else { throw TranscriptionFailure.runtime(error) }
                }
                completedSuccessfully = response.error == nil
                SpeechModelController.shared.transcriptionFinished(engine:activeModel ?? "",succeeded:completedSuccessfully)
            } catch is CancellationError {
                // Quit pauses work. Preserve the sidecar and its reference for
                // next-launch recovery instead of turning cancellation into failure.
                if !stoppingFolders.contains(meeting.folder.path), !trashing.contains(meeting.folder.path) {
                    try? await Task.detached(priority:.userInitiated) {
                        try MeetingTranscriber.pauseForResume(directory:meeting.folder,id:meeting.id)
                    }.value
                    if !closing { retryDeferred = true }
                }
            } catch {
                // Worker crashes and bundle/decoder failures take the same retry path.
                try? await Task.detached(priority:.userInitiated) {
                    try MeetingTranscriber.setStatus(directory:meeting.folder,id:meeting.id,status:"failed")
                }.value
            }
            await Task.detached { SegmentedAudio.removeAbandonedScratch() }.value
            let finishedModel = activeModel ?? ""
            active = nil; activeModel = nil; task = nil
            if retryDeferred { known.remove(meeting.folder.path) }
            startNext()
            if retryDeferred, !closing, !trashing.contains(meeting.folder.path), !stoppingFolders.contains(meeting.folder.path) {
                let folder = meeting.folder
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for:.milliseconds(300))
                    guard let self, !self.closing, !self.paused,
                          !self.trashing.contains(folder.path), !self.stoppingFolders.contains(folder.path) else { return }
                    LibraryStore.shared.refresh(affected:folder)
                }
            }
            #if DEBUG
            if SettingsFixture.id != nil { fixtureCompletion?(meeting.folder,finishedModel,completedSuccessfully) }
            #endif
        }
    }
}

#if DEBUG
/// Private filesystem/RAM proof. The worker waits for explicit cancellation.
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
            // Enqueue must return while this test still owns the metadata lock.
            // A synchronous metadata write cannot pass by waiting for a timer
            // to unlock it: only completion of the action releases the lock.
            try await holdingDirectoryLock(session.directory) { queue.enqueue(meeting) }
            await queue.waitForFixturePreparation()
            guard queue.active == meeting.folder else { throw POSIXError(.EINVAL) }
            let document = try JSONSerialization.jsonObject(with:Data(contentsOf:session.directory.appendingPathComponent("meeting.json"))) as! [String:Any]
            guard (document["transcript"] as? [String:Any])?["status"] as? String == "queued" else { throw POSIXError(.EINVAL) }
            let input = Bundle.main.resourceURL!.appendingPathComponent("Fixtures/Library/main/root/Received-a0000000-0000-4000-8000-000000000006/original.opus")
            let source = root.deletingLastPathComponent().appendingPathComponent("Private source.opus")
            _ = try OpusStreamFile.rewrite(Data(contentsOf:input),tags:PortableMeetingTags.packet(),to:source)
            let file = try CassiniReader.read(contentsOf:source)
            let detail = MeetingDetailModel(meeting:MeetingPresentation.external(file,url:source),fileURL:source,frozen:true)
            queue.writeDown(detail); queue.writeDown(detail)
            // This awaits the owned import task; it does not initiate shutdown.
            await importer.waitForShutdown()
            guard !importer.isBusy else { throw POSIXError(.EBUSY) }
            let imported = try LibraryScanner(root:root).scan().meetings.filter { $0.state.origin == .received }
            guard imported.count == 1 else { throw POSIXError(.EINVAL) }
            let received = imported[0]
            await queue.waitForFixturePreparation()
            guard try LibraryScanner(root:root).scan().meetings.first(where:{ $0.id == received.id })?.state.transcript == .queued else { throw POSIXError(.EINVAL) }
            try await verifyConcurrentImportKeepsExportProgressAndCancel(root:root, source:source, exportedMeeting:received)
            try await verifyBannerRemovalPreservesSharedExportReceipts(exportedMeeting:received, scratch:root.deletingLastPathComponent())
            try await verifyActiveUserStopStaleScanFenceAndResume(root:root, activeSession:session, nextActive:received)
            // A second accepted import is owned by the same shutdown path.
            let another = root.deletingLastPathComponent().appendingPathComponent("Another source.opus")
            try FileManager.default.copyItem(at:source,to:another)
            let waiting = try RecordingSession(parent:root,title:"Queued before Quit",source:"macos")
            try waiting.addTrack(id:"mic",label:"Mic",kind:"microphone",sampleRate:16000,channels:1)
            try waiting.appendNative(id:"mic",pcm:Data(repeating:0,count:3200),offsetMs:0); try waiting.finish()
            try MeetingMetadataWriter(directory:waiting.directory,id:waiting.manifest.id).createIfNeeded()
            let waitingMeeting = try require(LibraryScanner(root:root).scan().meetings.first(where:{ $0.id == waiting.manifest.id }))
            try await holdingDirectoryLock(waiting.directory) {
                queue.enqueue(waitingMeeting)
                importer.open(another)
                await Task.yield()
                importer.beginShutdown(); queue.beginShutdown()
            }
            await importer.waitForShutdown(); await queue.waitForShutdown()
            guard !importer.isBusy, !queue.isBusy else { throw POSIXError(.EBUSY) }
            guard try LibraryScanner(root:root).scan().meetings.first(where:{ $0.id == waiting.manifest.id })?.state.transcript == .queued else { throw POSIXError(.EINVAL) }
            for name in try FileManager.default.contentsOfDirectory(atPath:root.path) where name.hasPrefix("Received-") {
                guard FileManager.default.fileExists(atPath:root.appendingPathComponent(name + "/meeting.json").path) else { throw POSIXError(.EINVAL) }
            }
            try FileManager.default.removeItem(at:root.deletingLastPathComponent())
            let report = ["queueMetadataOffMain":true,"enqueueReturnedBeforeLockRelease":true,"shutdownStartedBeforeLockRelease":true,"metadataBeforeWorker":true,"repeatedWriteDownImportsOnce":true,"shutdownWaitsForImport":true,"queuedIntentSurvivesQuit":true,"concurrentImportKeepsExportProgressAndCancel":true,"bannerRemovalPreservesSharedExportReceipt":true,"userStopPreservesAndResumesWithoutAutoRestart":true,"audioDevicesOpened":false]
            FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject:report,options:[.sortedKeys]) + Data([10])); exit(0)
        } catch {
            importer.beginShutdown(); queue.beginShutdown()
            BulkZipExportCoordinator.shared.beginShutdown(); MeetingExportCoordinator.shared.beginShutdown()
            await importer.waitForShutdown(); await queue.waitForShutdown()
            await BulkZipExportCoordinator.shared.waitForShutdown(); await MeetingExportCoordinator.shared.waitForShutdown()
            try? FileManager.default.removeItem(at:root.deletingLastPathComponent())
            FileHandle.standardError.write(Data("Import lifecycle proof failed: \(error)\n".utf8)); exit(1)
        }
    }
    private static func holdingDirectoryLock(_ folder: URL, action: @MainActor () async throws -> Void) async throws {
        let fd = open(folder.path,O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue:errno) ?? .EIO) }
        defer { flock(fd,LOCK_UN); close(fd) }
        guard flock(fd,LOCK_EX | LOCK_NB) == 0 else { throw POSIXError(POSIXErrorCode(rawValue:errno) ?? .EIO) }
        try await action()
    }
    private static func require<T>(_ value: T?) throws -> T { guard let value else { throw POSIXError(.EINVAL) }; return value }

    private final class GateLatch: @unchecked Sendable {
        private let condition = NSCondition()
        private var entered = false
        private var released = false
        private var onEnter: (@Sendable () -> Void)?

        init(onEnter: @escaping @Sendable () -> Void) {
            self.onEnter = onEnter
        }

        func enterAndWait() {
            let callback: (@Sendable () -> Void)?
            condition.lock()
            if !entered {
                entered = true
                callback = onEnter
                onEnter = nil
            } else {
                callback = nil
            }
            callback?()
            while !released {
                condition.wait()
            }
            condition.unlock()
        }

        func release() {
            condition.lock()
            released = true
            condition.broadcast()
            condition.unlock()
        }
    }

    private static func verifyConcurrentImportKeepsExportProgressAndCancel(root: URL, source: URL, exportedMeeting: LibraryMeeting) async throws {
        let importer = LibraryImportCoordinator.shared
        let bulkExporter = BulkZipExportCoordinator.shared
        let scratch = root.deletingLastPathComponent()
        let batchA = scratch.appendingPathComponent("Batch-A.opus")
        let batchB = scratch.appendingPathComponent("Batch-B.opus")
        let raw = try Data(contentsOf: source)
        _ = try OpusStreamFile.rewrite(raw, tags: PortableMeetingTags.packet(comments: [Comment(name: "TITLE", value: "Batch A")]), to: batchA)
        _ = try OpusStreamFile.rewrite(raw, tags: PortableMeetingTags.packet(comments: [Comment(name: "TITLE", value: "Batch B")]), to: batchB)
        let zipDest = scratch.appendingPathComponent("ConcurrentCancelled.zip")

        let (exportEnteredStream, exportEnteredCont) = AsyncStream<Void>.makeStream()
        let exportLatch = GateLatch { exportEnteredCont.yield(()); exportEnteredCont.finish() }
        let (importEnteredStream, importEnteredCont) = AsyncStream<Void>.makeStream()
        let importLatch = GateLatch { importEnteredCont.yield(()); importEnteredCont.finish() }

        defer {
            exportLatch.release()
            importLatch.release()
            bulkExporter.fixtureOnProgressGate = nil
            importer.fixtureOnProgressGate = nil
            importer.dismissNotice()
        }

        bulkExporter.fixtureOnProgressGate = { done, _ in
            if done == 1 { exportLatch.enterAndWait() }
        }
        importer.fixtureOnProgressGate = { done, _ in
            if done == 1 { importLatch.enterAndWait() }
        }

        let (renderedCardsStream, renderedCardsCont) = AsyncStream<[TransferBannerPresentation.Card]>.makeStream()
        let host = NSHostingView(rootView: TransferStatusBanner(fixtureVisibleCards: { cards in
            renderedCardsCont.yield(cards)
        }))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        host.layoutSubtreeIfNeeded()
        defer {
            renderedCardsCont.finish()
            window.close()
        }

        var cardsIter = renderedCardsStream.makeAsyncIterator()
        func waitForRenderedCards(
            label: String,
            matching predicate: @escaping @Sendable ([TransferBannerPresentation.Card]) -> Bool
        ) async throws {
            let (cancelledStream, cancelledCont) = AsyncStream<Void>.makeStream()
            let timeoutTask = Task { @MainActor in
                defer {
                    cancelledCont.yield(())
                    cancelledCont.finish()
                }
                do { try await Task.sleep(for: .seconds(10)) } catch { return }
                renderedCardsCont.finish()
            }
            while let cards = await cardsIter.next() {
                if predicate(cards) {
                    timeoutTask.cancel()
                    await timeoutTask.value
                    var cancelledIter = cancelledStream.makeAsyncIterator()
                    _ = await cancelledIter.next()
                    return
                }
            }
            timeoutTask.cancel()
            await timeoutTask.value
            throw NSError(domain: "ImportLifecycleSelfTest", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing rendered banner cards: \(label)"])
        }

        bulkExporter.startExportForTesting([exportedMeeting, exportedMeeting], to: zipDest)
        var exportIter = exportEnteredStream.makeAsyncIterator()
        _ = await exportIter.next()

        importer.openBatch([batchA, batchB])
        var importIter = importEnteredStream.makeAsyncIterator()
        _ = await importIter.next()
        host.layoutSubtreeIfNeeded()

        try await waitForRenderedCards(label: "both import and export progress + cancel") { cards in
            let primaryIDs = Set(cards.map(\.primaryAccessibilityID))
            let actionIDs = Set(cards.map(\.actionAccessibilityID))
            return primaryIDs.contains("import-progress") && primaryIDs.contains("export-zip-progress") &&
                   actionIDs.contains("import-cancel") && actionIDs.contains("export-zip-cancel")
        }
        guard importer.progress != nil, bulkExporter.progress != nil else { throw POSIXError(.EINVAL) }

        // Cancel export while concurrent import remains active; import must stay running and complete.
        bulkExporter.cancel()
        exportLatch.release()
        await bulkExporter.waitForShutdown()
        host.layoutSubtreeIfNeeded()
        guard bulkExporter.progress == nil, !FileManager.default.fileExists(atPath: zipDest.path) else {
            throw POSIXError(.EINVAL)
        }
        guard importer.progress != nil else { throw POSIXError(.EINVAL) }
        try await waitForRenderedCards(label: "import progress retained after export cancel") { cards in
            let primaryIDs = Set(cards.map(\.primaryAccessibilityID))
            let actionIDs = Set(cards.map(\.actionAccessibilityID))
            return primaryIDs.contains("import-progress") && !primaryIDs.contains("export-zip-progress") &&
                   actionIDs.contains("import-cancel") && !actionIDs.contains("export-zip-cancel")
        }

        importLatch.release()
        await importer.waitForShutdown()
        guard !importer.isBusy, importer.notice != nil else { throw POSIXError(.EINVAL) }
        importer.dismissNotice()
    }

    @Observable fileprivate final class HostedBannerMount {
        var isMounted = true
    }

    fileprivate struct HostedBannerContainer: View {
        var mount: HostedBannerMount
        var onVisibleCards: ([TransferBannerPresentation.Card]) -> Void
        var onCleanup: () -> Void

        var body: some View {
            if mount.isMounted {
                TransferStatusBanner(
                    fixtureVisibleCards: onVisibleCards,
                    fixtureOnCleanup: onCleanup
                )
            }
        }
    }

    private static func verifyBannerRemovalPreservesSharedExportReceipts(exportedMeeting: LibraryMeeting, scratch: URL) async throws {
        let importer = LibraryImportCoordinator.shared
        let bulkExporter = BulkZipExportCoordinator.shared
        let singleExporter = MeetingExportCoordinator.shared

        func waitOnStream(
            iterator: inout AsyncStream<[TransferBannerPresentation.Card]>.AsyncIterator,
            continuation: AsyncStream<[TransferBannerPresentation.Card]>.Continuation,
            label: String,
            matching predicate: @escaping @Sendable ([TransferBannerPresentation.Card]) -> Bool
        ) async throws {
            let (cancelledStream, cancelledCont) = AsyncStream<Void>.makeStream()
            let timeoutTask = Task { @MainActor in
                defer {
                    cancelledCont.yield(())
                    cancelledCont.finish()
                }
                do { try await Task.sleep(for: .seconds(10)) } catch { return }
                continuation.finish()
            }
            while let cards = await iterator.next() {
                if predicate(cards) {
                    timeoutTask.cancel()
                    await timeoutTask.value
                    var cancelledIter = cancelledStream.makeAsyncIterator()
                    _ = await cancelledIter.next()
                    return
                }
            }
            timeoutTask.cancel()
            await timeoutTask.value
            throw NSError(domain: "ImportLifecycleSelfTest", code: 2, userInfo: [NSLocalizedDescriptionKey: "Missing rendered banner cards: \(label)"])
        }

        func waitForCleanup(
            stream: AsyncStream<Void>,
            continuation: AsyncStream<Void>.Continuation,
            label: String
        ) async throws {
            var iter = stream.makeAsyncIterator()
            let timeoutTask = Task { @MainActor in
                do { try await Task.sleep(for: .seconds(10)) } catch { return }
                continuation.finish()
            }
            let event: Void? = await iter.next()
            timeoutTask.cancel()
            await timeoutTask.value
            guard event != nil else {
                throw NSError(domain: "ImportLifecycleSelfTest", code: 6, userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for banner cleanup: \(label)"])
            }
        }

        func makeBannerWindow(
            continuation: AsyncStream<[TransferBannerPresentation.Card]>.Continuation,
            cleanupContinuation: AsyncStream<Void>.Continuation,
            onUpdate: (([TransferBannerPresentation.Card]) -> Void)? = nil
        ) -> (window: NSWindow, host: NSHostingView<HostedBannerContainer>, mount: HostedBannerMount) {
            let mount = HostedBannerMount()
            let host = NSHostingView(rootView: HostedBannerContainer(
                mount: mount,
                onVisibleCards: { cards in
                    onUpdate?(cards)
                    continuation.yield(cards)
                },
                onCleanup: {
                    cleanupContinuation.yield(())
                    cleanupContinuation.finish()
                }
            ))
            let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 240), styleMask: [.titled], backing: .buffered, defer: false)
            win.isReleasedWhenClosed = false
            win.contentView = host
            win.orderFront(nil)
            host.layoutSubtreeIfNeeded()
            return (win, host, mount)
        }

        var latestOpenCards: [TransferBannerPresentation.Card] = []
        let (openStream, openCont) = AsyncStream<[TransferBannerPresentation.Card]>.makeStream()
        let (_, openCleanupCont) = AsyncStream<Void>.makeStream()
        let (openWindow, openHost, openMount) = makeBannerWindow(continuation: openCont, cleanupContinuation: openCleanupCont) { cards in
            latestOpenCards = cards
        }
        var openIter = openStream.makeAsyncIterator()
        defer {
            openCont.finish()
            openCleanupCont.finish()
            openMount.isMounted = false
            openWindow.contentView = nil
            openWindow.close()
            if let id = bulkExporter.receipt?.id { bulkExporter.clearReceipt(id) }
            singleExporter.clearReceiptIfAny()
            importer.dismissNotice()
        }

        // 1. Bulk .zip export receipt remains visible in openWindow when secondWindow's banner is removed.
        let (bulkClosingStream, bulkClosingCont) = AsyncStream<[TransferBannerPresentation.Card]>.makeStream()
        let (bulkCleanupStream, bulkCleanupCont) = AsyncStream<Void>.makeStream()
        let (bulkClosingWin, bulkClosingHost, bulkClosingMount) = makeBannerWindow(
            continuation: bulkClosingCont,
            cleanupContinuation: bulkCleanupCont
        )
        var bulkClosingIter = bulkClosingStream.makeAsyncIterator()
        defer {
            bulkClosingCont.finish()
            bulkCleanupCont.finish()
            bulkClosingMount.isMounted = false
            bulkClosingWin.contentView = nil
            bulkClosingWin.close()
        }

        let bulkZipURL = scratch.appendingPathComponent("ReceiptPreserved.zip")
        bulkExporter.startExportForTesting([exportedMeeting], to: bulkZipURL)
        await bulkExporter.waitForShutdown()
        openHost.layoutSubtreeIfNeeded()
        bulkClosingHost.layoutSubtreeIfNeeded()

        let hasBulkReceipt: @Sendable ([TransferBannerPresentation.Card]) -> Bool = { cards in
            cards.contains { $0.primaryAccessibilityID == "export-zip-success" && $0.actionAccessibilityID == "export-zip-show" }
        }
        try await waitOnStream(iterator: &openIter, continuation: openCont, label: "openWindow bulk receipt", matching: hasBulkReceipt)
        try await waitOnStream(iterator: &bulkClosingIter, continuation: bulkClosingCont, label: "closingWindow bulk receipt", matching: hasBulkReceipt)
        let bulkReceiptID = try require(bulkExporter.receipt?.id)

        bulkClosingMount.isMounted = false
        bulkClosingHost.layoutSubtreeIfNeeded()
        bulkClosingWin.contentView = nil
        bulkClosingWin.close()
        try await waitForCleanup(stream: bulkCleanupStream, continuation: bulkCleanupCont, label: "bulk banner disappearance and task cancellation")
        openHost.layoutSubtreeIfNeeded()
        guard bulkExporter.receipt?.id == bulkReceiptID, hasBulkReceipt(latestOpenCards) else {
            throw NSError(domain: "ImportLifecycleSelfTest", code: 3, userInfo: [NSLocalizedDescriptionKey: "Bulk export receipt dismissed early upon banner removal"])
        }
        bulkExporter.clearReceipt(bulkReceiptID)

        // 2. Single-meeting export receipt remains visible in openWindow when another banner is removed.
        let (singleClosingStream, singleClosingCont) = AsyncStream<[TransferBannerPresentation.Card]>.makeStream()
        let (singleCleanupStream, singleCleanupCont) = AsyncStream<Void>.makeStream()
        let (singleClosingWin, singleClosingHost, singleClosingMount) = makeBannerWindow(
            continuation: singleClosingCont,
            cleanupContinuation: singleCleanupCont
        )
        var singleClosingIter = singleClosingStream.makeAsyncIterator()
        defer {
            singleClosingCont.finish()
            singleCleanupCont.finish()
            singleClosingMount.isMounted = false
            singleClosingWin.contentView = nil
            singleClosingWin.close()
        }

        let singleURL = scratch.appendingPathComponent("ReceiptPreservedSingle.opus")
        singleExporter.startExportForTesting(exportedMeeting, kind: .cassini, to: singleURL)
        await singleExporter.waitForShutdown()
        openHost.layoutSubtreeIfNeeded()
        singleClosingHost.layoutSubtreeIfNeeded()

        let hasSingleReceipt: @Sendable ([TransferBannerPresentation.Card]) -> Bool = { cards in
            cards.contains { $0.primaryAccessibilityID == "export-success" && $0.actionAccessibilityID == "export-show" }
        }
        try await waitOnStream(iterator: &openIter, continuation: openCont, label: "openWindow single receipt", matching: hasSingleReceipt)
        try await waitOnStream(iterator: &singleClosingIter, continuation: singleClosingCont, label: "closingWindow single receipt", matching: hasSingleReceipt)
        let singleReceiptID = try require(singleExporter.receipt?.id)

        singleClosingMount.isMounted = false
        singleClosingHost.layoutSubtreeIfNeeded()
        singleClosingWin.contentView = nil
        singleClosingWin.close()
        try await waitForCleanup(stream: singleCleanupStream, continuation: singleCleanupCont, label: "single banner disappearance and task cancellation")
        openHost.layoutSubtreeIfNeeded()
        guard singleExporter.receipt?.id == singleReceiptID, hasSingleReceipt(latestOpenCards) else {
            throw NSError(domain: "ImportLifecycleSelfTest", code: 4, userInfo: [NSLocalizedDescriptionKey: "Single export receipt dismissed early upon banner removal"])
        }
        singleExporter.clearReceipt(singleReceiptID)

        // 3. Auto-dismiss import notice remains visible in openWindow when another banner is removed.
        let (noticeClosingStream, noticeClosingCont) = AsyncStream<[TransferBannerPresentation.Card]>.makeStream()
        let (noticeCleanupStream, noticeCleanupCont) = AsyncStream<Void>.makeStream()
        let (noticeClosingWin, noticeClosingHost, noticeClosingMount) = makeBannerWindow(
            continuation: noticeClosingCont,
            cleanupContinuation: noticeCleanupCont
        )
        var noticeClosingIter = noticeClosingStream.makeAsyncIterator()
        defer {
            noticeClosingCont.finish()
            noticeCleanupCont.finish()
            noticeClosingMount.isMounted = false
            noticeClosingWin.contentView = nil
            noticeClosingWin.close()
        }

        importer.openBatch([singleURL, singleURL])
        await importer.waitForShutdown()
        openHost.layoutSubtreeIfNeeded()
        noticeClosingHost.layoutSubtreeIfNeeded()

        let hasImportSummary: @Sendable ([TransferBannerPresentation.Card]) -> Bool = { cards in
            cards.contains { $0.primaryAccessibilityID == "import-summary" && $0.actionAccessibilityID == "import-notice-done" }
        }
        try await waitOnStream(iterator: &openIter, continuation: openCont, label: "openWindow import summary", matching: hasImportSummary)
        try await waitOnStream(iterator: &noticeClosingIter, continuation: noticeClosingCont, label: "closingWindow import summary", matching: hasImportSummary)
        let noticeID = try require(importer.notice?.id)
        guard importer.notice?.autoDismiss == true else { throw POSIXError(.EINVAL) }

        noticeClosingMount.isMounted = false
        noticeClosingHost.layoutSubtreeIfNeeded()
        noticeClosingWin.contentView = nil
        noticeClosingWin.close()
        try await waitForCleanup(stream: noticeCleanupStream, continuation: noticeCleanupCont, label: "import notice banner disappearance and task cancellation")
        openHost.layoutSubtreeIfNeeded()
        guard importer.notice?.id == noticeID, hasImportSummary(latestOpenCards) else {
            throw NSError(domain: "ImportLifecycleSelfTest", code: 5, userInfo: [NSLocalizedDescriptionKey: "Auto-dismiss import notice dismissed early upon banner removal"])
        }
        importer.dismissNotice(noticeID)
    }

    private static func verifyActiveUserStopStaleScanFenceAndResume(root: URL, activeSession: RecordingSession, nextActive: LibraryMeeting) async throws {
        let queue = TranscriptionQueue.shared
        guard queue.active == activeSession.directory else { throw POSIXError(.EINVAL) }
        let sidecar = activeSession.directory.appendingPathComponent("transcript.json")
        let partial = try JSONSerialization.data(withJSONObject:[
            "language":"en",
            "items":[["speaker":"me","startMs":0,"endMs":200,"text":"Partial"]]
        ])
        try partial.write(to:sidecar)
        try MeetingMetadataWriter(directory:activeSession.directory,id:activeSession.manifest.id).transaction { meta in
            meta["transcript"] = [
                "status":"running",
                "model":"whistle",
                "reference":["kind":"sidecar","file":"transcript.json","format":"cassini.words.v1"]
            ]
        }
        let staleRunning = try require(LibraryScanner(root:root).scan().meetings.first(where:{ $0.id == activeSession.manifest.id }))
        guard staleRunning.state.transcript == .running else { throw POSIXError(.EINVAL) }
        queue.stop(staleRunning)
        for _ in 0..<200 {
            if !queue.isStopping(activeSession.directory) { break }
            try await Task.sleep(for:.milliseconds(25))
        }
        guard !queue.isStopping(activeSession.directory), queue.active == nextActive.folder else {
            throw NSError(domain:"ImportLifecycleSelfTest",code:7,userInfo:[NSLocalizedDescriptionKey:"Stopping active worker did not settle cleanly and promote next job"])
        }
        let stopped = try require(LibraryScanner(root:root).scan().meetings.first(where:{ $0.id == activeSession.manifest.id }))
        guard stopped.state.transcript == .none, stopped.transcriptPaused, !stopped.canQueueAutomatically,
              stopped.transcriptItems.map(\.text) == ["Partial"] else {
            throw NSError(domain:"ImportLifecycleSelfTest",code:8,userInfo:[NSLocalizedDescriptionKey:"Stopped meeting did not preserve partial words in paused state"])
        }
        // Neither a stale pre-stop scan nor a fresh automatic scan may restart a user-stopped job.
        queue.consider([staleRunning],automatic:true)
        await queue.waitForFixturePreparation()
        let afterStale = try require(LibraryScanner(root:root).scan().meetings.first(where:{ $0.id == activeSession.manifest.id }))
        guard afterStale.state.transcript == .none, afterStale.transcriptPaused else {
            throw NSError(domain:"ImportLifecycleSelfTest",code:9,userInfo:[NSLocalizedDescriptionKey:"Stale running scan re-enqueued user-stopped meeting"])
        }
        queue.consider(try LibraryScanner(root:root).scan().meetings,automatic:true)
        await queue.waitForFixturePreparation()
        let afterFresh = try require(LibraryScanner(root:root).scan().meetings.first(where:{ $0.id == activeSession.manifest.id }))
        guard afterFresh.state.transcript == .none, afterFresh.transcriptPaused else {
            throw NSError(domain:"ImportLifecycleSelfTest",code:10,userInfo:[NSLocalizedDescriptionKey:"Automatic consider re-enqueued user-stopped meeting"])
        }
        // Explicit user Resume re-queues the meeting and keeps the partial reference.
        queue.enqueue(afterFresh)
        await queue.waitForFixturePreparation()
        let resumed = try require(LibraryScanner(root:root).scan().meetings.first(where:{ $0.id == activeSession.manifest.id }))
        guard resumed.state.transcript == .queued, !resumed.transcriptPaused,
              resumed.writtenTranscriptItems.map(\.text) == ["Partial"] else {
            throw NSError(domain:"ImportLifecycleSelfTest",code:11,userInfo:[NSLocalizedDescriptionKey:"Explicit resume did not queue meeting with preserved partial words"])
        }
        queue.stop(resumed)
        for _ in 0..<200 {
            if !queue.isStopping(activeSession.directory) { break }
            try await Task.sleep(for:.milliseconds(25))
        }
        guard !queue.isStopping(activeSession.directory) else { throw POSIXError(.EBUSY) }
    }
}
#endif
