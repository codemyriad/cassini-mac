// SPDX-License-Identifier: GPL-3.0-or-later
#if DEBUG
import AppKit
import AVFoundation
import AudioToolbox
import CassiniExport
import CassiniKit
import CassiniLibrary
import CassiniRecording
import CassiniTranscription
import Darwin
import SwiftUI

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
            try await verifyActiveUserStopStaleScanFenceAndResume(root:root, activeSession:session, activeMeeting:meeting, nextActive:received)
            try await verifyLockContentionCompletionWhileRetryPending(root:root, blockerID:received.id)
            try await verifyStopCoordinatesWithMoveAndTrashUnderMetadataLock(root:root)
            try await verifyDesktopAudioImportDropAndTransientCards(root:root)
            // A second accepted import and an accepted Stop are owned by the same shutdown path.
            let another = root.deletingLastPathComponent().appendingPathComponent("Another source.opus")
            try FileManager.default.copyItem(at:source,to:another)
            let waiting = try RecordingSession(parent:root,title:"Queued before Quit",source:"macos")
            try waiting.addTrack(id:"mic",label:"Mic",kind:"microphone",sampleRate:16000,channels:1)
            try waiting.appendNative(id:"mic",pcm:Data(repeating:0,count:3200),offsetMs:0); try waiting.finish()
            try MeetingMetadataWriter(directory:waiting.directory,id:waiting.manifest.id).createIfNeeded()
            let waitingMeeting = try require(LibraryScanner(root:root).scan().meetings.first(where:{ $0.id == waiting.manifest.id }))
            try await verifyStopCommitsBeforeShutdownCompletes(root:root, waiting:waiting, waitingMeeting:waitingMeeting, anotherSource:another)
            guard !importer.isBusy, !queue.isBusy else { throw POSIXError(.EBUSY) }
            guard try LibraryScanner(root:root).scan().meetings.first(where:{ $0.id == waiting.manifest.id })?.state.transcript == .queued else { throw POSIXError(.EINVAL) }
            for name in try FileManager.default.contentsOfDirectory(atPath:root.path) where name.hasPrefix("Received-") {
                guard FileManager.default.fileExists(atPath:root.appendingPathComponent(name + "/meeting.json").path) else { throw POSIXError(.EINVAL) }
            }
            try FileManager.default.removeItem(at:root.deletingLastPathComponent())
            let report = ["queueMetadataOffMain":true,"enqueueReturnedBeforeLockRelease":true,"shutdownStartedBeforeLockRelease":true,"metadataBeforeWorker":true,"repeatedWriteDownImportsOnce":true,"shutdownWaitsForImport":true,"queuedIntentSurvivesQuit":true,"concurrentImportKeepsExportProgressAndCancel":true,"bannerRemovalPreservesSharedExportReceipt":true,"singleImportConfirmationAndSilentReopen":true,"userStopPreservesAndResumesWithoutAutoRestart":true,"lockContentionRetryPreservesCompletedTranscript":true,"stopCommitsBeforeShutdownMoveAndTrash":true,"desktopAudioDecodeDropAndTransientCards":true,"audioDevicesOpened":false]
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

        // Exercise the dialog's primary format for this plain-audio fixture
        // while its transcript is queued.
        let singleKind = try require(MeetingExportKind.primary(for:exportedMeeting).first)
        let singleURL = scratch.appendingPathComponent("ReceiptPreservedSingle." + singleKind.suffix(for:exportedMeeting))
        singleExporter.startExportForTesting(exportedMeeting, kind:singleKind, to:singleURL)
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

        // A fresh single-file open shows the one-time confirmation. Reopening
        // the same file must clear it without creating another Library entry.
        let firstOpenURL = scratch.appendingPathComponent("FirstOpenConfirmation.opus")
        _ = try OpusStreamFile.rewrite(Data(contentsOf:singleURL), tags:PortableMeetingTags.packet(comments:[Comment(name:"TITLE",value:"First open confirmation")]), to:firstOpenURL)
        importer.open(firstOpenURL)
        await importer.waitForShutdown()
        let firstNotice = try require(importer.notice)
        guard firstNotice.message == UXText.text("received.importedToast",["folder":scratch.lastPathComponent]),
              !firstNotice.isWarning, firstNotice.autoDismiss else {
            throw NSError(domain:"ImportLifecycleSelfTest",code:27,userInfo:[NSLocalizedDescriptionKey:"Single import did not show its first-open confirmation"])
        }
        importer.open(firstOpenURL)
        await importer.waitForShutdown()
        guard importer.notice == nil else {
            throw NSError(domain:"ImportLifecycleSelfTest",code:28,userInfo:[NSLocalizedDescriptionKey:"Duplicate single-file open showed an import confirmation"])
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

    private static func verifyActiveUserStopStaleScanFenceAndResume(root: URL, activeSession: RecordingSession, activeMeeting: LibraryMeeting, nextActive: LibraryMeeting) async throws {
        let queue = TranscriptionQueue.shared
        guard queue.active == activeMeeting.folder else {
            throw NSError(domain:"ImportLifecycleSelfTest",code:20,userInfo:[NSLocalizedDescriptionKey:"Expected active folder \(activeMeeting.folder.path), got \(queue.active?.path ?? "nil")"])
        }
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
        guard staleRunning.state.transcript == .running else {
            throw NSError(domain:"ImportLifecycleSelfTest",code:21,userInfo:[NSLocalizedDescriptionKey:"Expected staleRunning transcript status .running, got \(staleRunning.state.transcript)"])
        }
        await queue.stop(staleRunning)?.value
        guard !queue.isStopping(staleRunning.folder), queue.active == nextActive.folder else {
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
        await queue.stop(resumed)?.value
        guard !queue.isStopping(resumed.folder) else { throw POSIXError(.EBUSY) }
    }

    private static func awaitWithTimeout<T: Sendable>(
        stream: AsyncStream<T>,
        continuation: AsyncStream<T>.Continuation,
        label: String,
        matching predicate: @escaping @Sendable (T) -> Bool
    ) async throws {
        var iterator = stream.makeAsyncIterator()
        let (cancelledStream, cancelledCont) = AsyncStream<Void>.makeStream()
        let timeoutTask = Task { @MainActor in
            defer { cancelledCont.yield(()); cancelledCont.finish() }
            do { try await Task.sleep(for:.seconds(10)) } catch { return }
            continuation.finish()
        }
        while let element = await iterator.next() {
            if predicate(element) {
                timeoutTask.cancel()
                await timeoutTask.value
                var cancelledIter = cancelledStream.makeAsyncIterator()
                _ = await cancelledIter.next()
                return
            }
        }
        timeoutTask.cancel()
        await timeoutTask.value
        throw NSError(domain:"ImportLifecycleSelfTest",code:12,userInfo:[NSLocalizedDescriptionKey:"Timed out waiting for event: \(label)"])
    }

    private static func verifyLockContentionCompletionWhileRetryPending(root: URL, blockerID: UUID) async throws {
        let queue = TranscriptionQueue.shared
        let activeBlocker = try require(LibraryScanner(root:root).scan().meetings.first(where:{ $0.id == blockerID }))
        await queue.stop(activeBlocker)?.value
        guard queue.active == nil else { throw POSIXError(.EBUSY) }

        let contended = try RecordingSession(parent:root,title:"Shared library contention",source:"chromium")
        try contended.addTrack(id:"remote",label:"Remote",kind:"remote",sampleRate:16000,channels:1)
        try contended.appendNative(id:"remote",pcm:Data(repeating:0,count:3200),offsetMs:0); try contended.finish()
        try MeetingMetadataWriter(directory:contended.directory,id:contended.manifest.id).transaction { meta in
            meta["transcript"] = ["status":"running","model":"whistle","reference":NSNull()]
        }
        let contendedRunning = try require(LibraryScanner(root:root).scan().meetings.first(where:{ $0.id == contended.manifest.id }))
        let lockPath = contendedRunning.folder.appendingPathComponent(".transcription.lock").path
        var lockFD = open(lockPath, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard lockFD >= 0 else { throw POSIXError(POSIXErrorCode(rawValue:errno) ?? .EIO) }
        defer {
            if lockFD >= 0 { flock(lockFD, LOCK_UN); close(lockFD) }
        }
        guard flock(lockFD, LOCK_EX | LOCK_NB) == 0 else { throw POSIXError(POSIXErrorCode(rawValue:errno) ?? .EIO) }

        let (outcomeStream, outcomeCont) = AsyncStream<(URL, TranscriptionQueue.AttemptOutcome)>.makeStream()
        queue.fixtureOnAttemptOutcome = { folder, outcome in outcomeCont.yield((folder, outcome)) }
        defer {
            queue.fixtureOnAttemptOutcome = nil
            outcomeCont.finish()
        }

        let targetPath = contendedRunning.folder.path
        queue.consider([contendedRunning], automatic:true)
        try await awaitWithTimeout(stream:outcomeStream, continuation:outcomeCont, label:"initial lock contention") { folder, outcome in
            folder.path == targetPath && outcome == .lockContended
        }

        // Start a blocking job so the contended meeting's retry waits in `pending`.
        let stoppedBlocker = try require(LibraryScanner(root:root).scan().meetings.first(where:{ $0.id == blockerID }))
        queue.enqueue(stoppedBlocker)
        await queue.waitForFixturePreparation()
        guard queue.active == stoppedBlocker.folder else {
            throw NSError(domain:"ImportLifecycleSelfTest",code:22,userInfo:[NSLocalizedDescriptionKey:"Expected stoppedBlocker active"])
        }

        queue.consider([contendedRunning], automatic:true)
        await queue.waitForFixturePreparation()
        guard queue.containsPendingForTesting(contendedRunning.folder) else {
            throw NSError(domain:"ImportLifecycleSelfTest",code:13,userInfo:[NSLocalizedDescriptionKey:"Expected contended meeting retry to wait in pending behind active job"])
        }

        // While the retry is pending, the external lock owner completes the transcript and releases the lock.
        let completedSidecar = try JSONSerialization.data(withJSONObject:[
            "language":"en",
            "items":[
                ["speaker":"remote","startMs":0,"endMs":240,"text":"Completed"],
                ["speaker":"remote","startMs":260,"endMs":540,"text":"elsewhere"]
            ]
        ])
        try completedSidecar.write(to:contendedRunning.folder.appendingPathComponent("transcript.json"))
        try MeetingMetadataWriter(directory:contendedRunning.folder,id:contended.manifest.id).transaction { meta in
            meta["transcript"] = [
                "status":"done",
                "model":"whistle",
                "reference":["kind":"sidecar","file":"transcript.json","format":"cassini.words.v1"]
            ]
        }
        flock(lockFD, LOCK_UN); close(lockFD); lockFD = -1

        // Stop the blocker without rescanning first so `startNext()` pops the now-completed pending retry.
        let runningBlocker = try require(LibraryScanner(root:root).scan().meetings.first(where:{ $0.id == blockerID }))
        let (settledStream, settledCont) = AsyncStream<(URL, TranscriptionQueue.AttemptOutcome)>.makeStream()
        queue.fixtureOnAttemptOutcome = { folder, outcome in settledCont.yield((folder, outcome)) }
        defer { settledCont.finish() }
        await queue.stop(runningBlocker)?.value
        try await awaitWithTimeout(stream:settledStream, continuation:settledCont, label:"pending retry revalidated as alreadySettled") { folder, outcome in
            folder.path == targetPath && outcome == .alreadySettled
        }

        // Also prove generic failure handling never overwrites a completed attempt.
        let failDisposition = try MeetingTranscriber.failAttemptIfOwnedAndUnsettled(directory:contendedRunning.folder,id:contended.manifest.id)
        guard failDisposition == .alreadySettled else {
            throw NSError(domain:"ImportLifecycleSelfTest",code:14,userInfo:[NSLocalizedDescriptionKey:"Failure handler did not treat completed meeting as alreadySettled"])
        }
        let verified = try require(LibraryScanner(root:root).scan().meetings.first(where:{ $0.id == contended.manifest.id }))
        guard verified.state.transcript == .done, verified.transcriptReferenced,
              verified.transcriptItems.map(\.text) == ["Completed","elsewhere"],
              verified.state.error == nil else {
            throw NSError(domain:"ImportLifecycleSelfTest",code:15,userInfo:[NSLocalizedDescriptionKey:"Completed transcript was invalidated by pending retry or failure handler"])
        }

        // Restore the active blocker so subsequent lifecycle checks run in the same steady state.
        let restoreBlocker = try require(LibraryScanner(root:root).scan().meetings.first(where:{ $0.id == blockerID }))
        queue.enqueue(restoreBlocker)
        await queue.waitForFixturePreparation()
        guard queue.active == restoreBlocker.folder else {
            throw NSError(domain:"ImportLifecycleSelfTest",code:23,userInfo:[NSLocalizedDescriptionKey:"Expected restoreBlocker active"])
        }

        // Also prove the scan-before-pop path: an automatic pending retry is pruned cleanly
        // when a library scan sees external completion before `startNext()` pops it.
        let scanPruned = try RecordingSession(parent:root,title:"Shared library scan prune",source:"chromium")
        try scanPruned.addTrack(id:"remote",label:"Remote",kind:"remote",sampleRate:16000,channels:1)
        try scanPruned.appendNative(id:"remote",pcm:Data(repeating:0,count:3200),offsetMs:0); try scanPruned.finish()
        try MeetingMetadataWriter(directory:scanPruned.directory,id:scanPruned.manifest.id).transaction { meta in
            meta["transcript"] = ["status":"running","model":"whistle","reference":NSNull()]
        }
        let scanPrunedRunning = try require(LibraryScanner(root:root).scan().meetings.first(where:{ $0.id == scanPruned.manifest.id }))
        queue.consider([scanPrunedRunning], automatic:true)
        await queue.waitForFixturePreparation()
        guard queue.containsPendingForTesting(scanPrunedRunning.folder),
              queue.isQueuedOrActive(scanPrunedRunning.folder) else {
            throw NSError(domain:"ImportLifecycleSelfTest",code:25,userInfo:[NSLocalizedDescriptionKey:"Expected scanPrunedRunning in pending and queued"])
        }
        try completedSidecar.write(to:scanPrunedRunning.folder.appendingPathComponent("transcript.json"))
        try MeetingMetadataWriter(directory:scanPrunedRunning.folder,id:scanPruned.manifest.id).transaction { meta in
            meta["transcript"] = [
                "status":"done",
                "model":"whistle",
                "reference":["kind":"sidecar","file":"transcript.json","format":"cassini.words.v1"]
            ]
        }
        queue.consider(try LibraryScanner(root:root).scan().meetings, automatic:true)
        guard !queue.containsPendingForTesting(scanPrunedRunning.folder) else {
            throw NSError(domain:"ImportLifecycleSelfTest",code:26,userInfo:[NSLocalizedDescriptionKey:"Completed automatic pending retry was not pruned by scan"])
        }
        guard !queue.isQueuedOrActive(scanPrunedRunning.folder) else {
            throw NSError(domain:"ImportLifecycleSelfTest",code:27,userInfo:[NSLocalizedDescriptionKey:"Pruned automatic pending retry remained marked queued/active"])
        }
    }

    private static func verifyStopCoordinatesWithMoveAndTrashUnderMetadataLock(root: URL) async throws {
        let queue = TranscriptionQueue.shared
        for kind in ["move", "trash"] {
            let session = try RecordingSession(parent:root,title:"Stop before \(kind)",source:"chromium")
            try session.addTrack(id:"remote",label:"Remote",kind:"remote",sampleRate:16000,channels:1)
            try session.appendNative(id:"remote",pcm:Data(repeating:0,count:3200),offsetMs:0); try session.finish()
            try MeetingMetadataWriter(directory:session.directory,id:session.manifest.id).transaction { meta in
                meta["transcript"] = ["status":"queued","model":"whistle","reference":NSNull()]
            }
            let meeting = try require(LibraryScanner(root:root).scan().meetings.first(where:{ $0.id == session.manifest.id }))

            var metadataLockFD = open(meeting.folder.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
            guard metadataLockFD >= 0 else { throw POSIXError(POSIXErrorCode(rawValue:errno) ?? .EIO) }
            defer {
                if metadataLockFD >= 0 { flock(metadataLockFD, LOCK_UN); close(metadataLockFD) }
            }
            guard flock(metadataLockFD, LOCK_EX | LOCK_NB) == 0 else { throw POSIXError(POSIXErrorCode(rawValue:errno) ?? .EIO) }

            let (willWriteStream, willWriteCont) = AsyncStream<URL>.makeStream()
            let (barrierStream, barrierCont) = AsyncStream<String>.makeStream()
            queue.fixtureOnStopMetadataWillWrite = { folder in willWriteCont.yield(folder) }
            queue.fixtureOnBarrierAwaitingStops = { phase in barrierCont.yield(phase) }
            defer {
                queue.fixtureOnStopMetadataWillWrite = nil
                queue.fixtureOnBarrierAwaitingStops = nil
                willWriteCont.finish()
                barrierCont.finish()
            }

            // Discard the returned Task, matching UI callers.
            _ = queue.stop(meeting)
            let expectedPath = meeting.folder.path
            try await awaitWithTimeout(stream:willWriteStream, continuation:willWriteCont, label:"stopForUser entered for \(kind)") { $0.path == expectedPath }

            var barrierCompleted = false
            let barrierTask = Task { @MainActor in
                if kind == "move" {
                    await queue.pauseForMove()
                } else {
                    await queue.cancel(meeting:meeting.folder)
                }
                barrierCompleted = true
            }
            try await awaitWithTimeout(stream:barrierStream, continuation:barrierCont, label:"\(kind) barrier awaiting stop") { $0 == kind }
            guard !barrierCompleted else {
                throw NSError(domain:"ImportLifecycleSelfTest",code:16,userInfo:[NSLocalizedDescriptionKey:"\(kind) finished before Stop committed under held metadata lock"])
            }
            flock(metadataLockFD, LOCK_UN); close(metadataLockFD); metadataLockFD = -1
            await barrierTask.value
            guard barrierCompleted, !queue.isStopping(meeting.folder) else { throw POSIXError(.EBUSY) }

            let committed = try require(LibraryScanner(root:root).scan().meetings.first(where:{ $0.id == session.manifest.id }))
            guard committed.state.transcript == .none, committed.transcriptPaused, !committed.canQueueAutomatically else {
                throw NSError(domain:"ImportLifecycleSelfTest",code:17,userInfo:[NSLocalizedDescriptionKey:"Accepted Stop did not commit paused state before \(kind) completed"])
            }
            if kind == "move" {
                queue.resumeAfterMove()
            } else {
                queue.releaseTrashed(meeting.folder)
            }
        }
    }

    private static func verifyStopCommitsBeforeShutdownCompletes(
        root: URL,
        waiting: RecordingSession,
        waitingMeeting: LibraryMeeting,
        anotherSource: URL
    ) async throws {
        let queue = TranscriptionQueue.shared, importer = LibraryImportCoordinator.shared
        let quitStopped = try RecordingSession(parent:root,title:"Stopped before Quit",source:"chromium")
        try quitStopped.addTrack(id:"remote",label:"Remote",kind:"remote",sampleRate:16000,channels:1)
        try quitStopped.appendNative(id:"remote",pcm:Data(repeating:0,count:3200),offsetMs:0); try quitStopped.finish()
        let quitSidecar = try JSONSerialization.data(withJSONObject:[
            "language":"en",
            "items":[["speaker":"remote","startMs":0,"endMs":220,"text":"BeforeQuit"]]
        ])
        try quitSidecar.write(to:quitStopped.directory.appendingPathComponent("transcript.json"))
        try MeetingMetadataWriter(directory:quitStopped.directory,id:quitStopped.manifest.id).transaction { meta in
            meta["transcript"] = [
                "status":"queued",
                "model":"whistle",
                "reference":["kind":"sidecar","file":"transcript.json","format":"cassini.words.v1"]
            ]
        }
        let quitStoppedMeeting = try require(LibraryScanner(root:root).scan().meetings.first(where:{ $0.id == quitStopped.manifest.id }))

        var stopLockFD = open(quitStoppedMeeting.folder.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard stopLockFD >= 0 else { throw POSIXError(POSIXErrorCode(rawValue:errno) ?? .EIO) }
        defer {
            if stopLockFD >= 0 { flock(stopLockFD, LOCK_UN); close(stopLockFD) }
        }
        guard flock(stopLockFD, LOCK_EX | LOCK_NB) == 0 else { throw POSIXError(POSIXErrorCode(rawValue:errno) ?? .EIO) }

        let (willWriteStream, willWriteCont) = AsyncStream<URL>.makeStream()
        let (barrierStream, barrierCont) = AsyncStream<String>.makeStream()
        queue.fixtureOnStopMetadataWillWrite = { folder in willWriteCont.yield(folder) }
        queue.fixtureOnBarrierAwaitingStops = { phase in barrierCont.yield(phase) }
        defer {
            queue.fixtureOnStopMetadataWillWrite = nil
            queue.fixtureOnBarrierAwaitingStops = nil
            willWriteCont.finish()
            barrierCont.finish()
        }

        // UI-identical call: discard the returned Stop task while holding the metadata lock.
        _ = queue.stop(quitStoppedMeeting)
        let quitTargetPath = quitStoppedMeeting.folder.path
        try await awaitWithTimeout(stream:willWriteStream, continuation:willWriteCont, label:"stopForUser entered before Quit") { $0.path == quitTargetPath }

        try await holdingDirectoryLock(waitingMeeting.folder) {
            queue.enqueue(waitingMeeting)
            importer.open(anotherSource)
            await Task.yield()
            importer.beginShutdown(); queue.beginShutdown()
        }
        await importer.waitForShutdown()

        var shutdownFinished = false
        let shutdownTask = Task { @MainActor in
            await queue.waitForShutdown()
            shutdownFinished = true
        }
        try await awaitWithTimeout(stream:barrierStream, continuation:barrierCont, label:"shutdown barrier awaiting Stop") { $0 == "shutdown" }
        guard !shutdownFinished, queue.isBusy else {
            throw NSError(domain:"ImportLifecycleSelfTest",code:18,userInfo:[NSLocalizedDescriptionKey:"waitForShutdown returned before accepted Stop committed"])
        }
        let stillQueuedWhileLocked = try require(LibraryScanner(root:root).scan().meetings.first(where:{ $0.id == quitStopped.manifest.id }))
        guard stillQueuedWhileLocked.state.transcript == .queued else {
            throw NSError(domain:"ImportLifecycleSelfTest",code:24,userInfo:[NSLocalizedDescriptionKey:"Expected quitStopped to remain .queued while lock held"])
        }

        flock(stopLockFD, LOCK_UN); close(stopLockFD); stopLockFD = -1
        await shutdownTask.value
        guard shutdownFinished, !queue.isBusy else { throw POSIXError(.EBUSY) }

        let committedAfterShutdown = try require(LibraryScanner(root:root).scan().meetings.first(where:{ $0.id == quitStopped.manifest.id }))
        guard committedAfterShutdown.state.transcript == .none,
              committedAfterShutdown.transcriptPaused,
              !committedAfterShutdown.canQueueAutomatically,
              committedAfterShutdown.transcriptItems.map(\.text) == ["BeforeQuit"] else {
            throw NSError(domain:"ImportLifecycleSelfTest",code:19,userInfo:[NSLocalizedDescriptionKey:"Accepted Stop did not persist paused state before shutdown finished"])
        }
    }

    private static func verifyDesktopAudioImportDropAndTransientCards(root: URL) async throws {
        let importer = LibraryImportCoordinator.shared
        let scratch = root.deletingLastPathComponent().appendingPathComponent("d1028-proof", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer {
            importer.fixtureOnSingleGate = nil
            importer.dismissNotice()
            try? FileManager.default.removeItem(at: scratch)
        }

        // 1. Generate synthetic WAV, M4A, MP3, and unsupported/disguised files without opening audio devices.
        let wavURL = scratch.appendingPathComponent("Design standup.wav")
        do {
            let fmt = try require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44_100, channels: 2, interleaved: false))
            let buf = try require(AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 22_050))
            buf.frameLength = 22_050
            for i in 0..<22_050 {
                let s = Float(sin(Double(i) * 2.0 * .pi * 440.0 / 44_100.0) * 0.35)
                buf.floatChannelData![0][i] = s
                buf.floatChannelData![1][i] = s * 0.5
            }
            let out = try AVAudioFile(
                forWriting: wavURL,
                settings: [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                    AVSampleRateKey: 44_100,
                    AVNumberOfChannelsKey: 2,
                    AVLinearPCMBitDepthKey: 16,
                    AVLinearPCMIsFloatKey: false,
                    AVLinearPCMIsBigEndianKey: false,
                    AVLinearPCMIsNonInterleaved: false,
                ],
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
            try out.write(from: buf)
        }

        let m4aURL = scratch.appendingPathComponent("Voice memo.m4a")
        do {
            let fmt = try require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44_100, channels: 1, interleaved: false))
            let buf = try require(AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 26_460))
            buf.frameLength = 26_460
            for i in 0..<26_460 {
                buf.floatChannelData![0][i] = Float(sin(Double(i) * 2.0 * .pi * 523.25 / 44_100.0) * 0.35)
            }
            let out = try AVAudioFile(
                forWriting: m4aURL,
                settings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: 44_100,
                    AVNumberOfChannelsKey: 1,
                    AVEncoderBitRateKey: 64_000,
                ]
            )
            try out.write(from: buf)
        }

        let mp3URL = scratch.appendingPathComponent("Field interview.mp3")
        do {
            var mp3Data = Data()
            for i in 0..<30 {
                var frame = Data(repeating: 0, count: 417)
                frame[0] = 0xFF; frame[1] = 0xFB; frame[2] = 0x90; frame[3] = 0xC4
                frame[416] = UInt8(i & 0xFF)
                mp3Data.append(frame)
            }
            try mp3Data.write(to: mp3URL)
        }

        let flacURL = scratch.appendingPathComponent("Lossless take.flac")
        try (Data("fLaC".utf8) + Data(repeating: 0, count: 40)).write(to: flacURL)
        let ogaURL = scratch.appendingPathComponent("Archive audio.oga")
        try (Data("OggS".utf8) + Data(repeating: 0, count: 40)).write(to: ogaURL)
        let theoraOggURL = scratch.appendingPathComponent("Screen clip.ogg")
        do {
            var page = Data("OggS".utf8) + Data([0, 0x02]) + Data(repeating: 0, count: 8) + Data([1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 42])
            page.append(Data([0x80]) + Data("theora".utf8) + Data([0x03, 0x02, 0x01]) + Data(repeating: 0, count: 32))
            try page.write(to: theoraOggURL)
        }
        let brokenMp3URL = scratch.appendingPathComponent("Damaged recording.mp3")
        try Data("corrupt-mp3-payload".utf8).write(to: brokenMp3URL)

        // Verify W4.4 drop-target URL classification and unsupported-file naming
        guard LibraryImportCoordinator.isSupportedDropURL(wavURL),
              LibraryImportCoordinator.isSupportedDropURL(m4aURL),
              LibraryImportCoordinator.isSupportedDropURL(mp3URL),
              LibraryImportCoordinator.isSupportedDropURL(flacURL),
              !LibraryImportCoordinator.isSupportedDropURL(ogaURL),
              !LibraryImportCoordinator.isSupportedDropURL(theoraOggURL) else {
            throw NSError(domain: "ImportLifecycleSelfTest", code: 30, userInfo: [NSLocalizedDescriptionKey: "Drop URL classification mismatch"])
        }
        let multiNames = LibraryDropState.formattedUnsupportedFileNames([ogaURL, theoraOggURL], locale: Locale(identifier: "en_GB"))
        guard multiNames.contains("Archive audio.oga") && multiNames.contains("Screen clip.ogg") else {
            throw NSError(domain: "ImportLifecycleSelfTest", code: 31, userInfo: [NSLocalizedDescriptionKey: "Expected unsupported drop state to name rejected files, got \(multiNames)"])
        }

        let proofDir = ProcessInfo.processInfo.environment["CASSINI_RENDER_D1028_PROOF_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        func renderProof(_ name: String, view: some View, width: CGFloat = 420, height: CGFloat = 420) throws {
            guard let proofDir else { return }
            try FileManager.default.createDirectory(at: proofDir, withIntermediateDirectories: true)
            for (scheme, suffix, appearanceName) in [(ColorScheme.light, "light", NSAppearance.Name.aqua), (ColorScheme.dark, "dark", NSAppearance.Name.darkAqua)] {
                let wrapped = view
                    .environment(\.colorScheme, scheme)
                    .frame(width: width, height: height)
                    .cassiniSidebarBackground()
                let host = NSHostingView(rootView: wrapped)
                host.appearance = NSAppearance(named: appearanceName)
                host.frame = NSRect(x: 0, y: 0, width: width, height: height)
                let win = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                win.isReleasedWhenClosed = false
                win.appearance = NSAppearance(named: appearanceName)
                win.contentView = host
                host.layoutSubtreeIfNeeded()
                guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
                host.cacheDisplay(in: host.bounds, to: rep)
                if let png = rep.representation(using: .png, properties: [:]) {
                    try png.write(to: proofDir.appendingPathComponent("\(name)-\(suffix).png"))
                }
                win.close()
            }
        }

        try renderProof(
            "w4-4-drop-unsupported",
            view: ZStack {
                VStack(alignment: .leading, spacing: 8) {
                    Text(UXText.text("format.today")).font(.system(size: 11.5, weight: .bold)).foregroundStyle(CassiniTheme.ink2)
                    MeetingCard(isSelected: false) {
                        Text("Weekly sync").font(.system(size: 13, weight: .semibold)).foregroundStyle(CassiniTheme.ink)
                    }
                    Spacer()
                }
                .padding(14)
                .opacity(0.30)
                LibraryDropListOverlay(state: .unsupportedOverList(fileName: multiNames))
            },
            width: 400,
            height: 280
        )

        // 2. Verify W4.5 `Importing…` card during active WAV decode, then completion.
        let (enteredStream, enteredCont) = AsyncStream<Void>.makeStream()
        let singleLatch = GateLatch { enteredCont.yield(()); enteredCont.finish() }
        importer.fixtureOnSingleGate = { singleLatch.enterAndWait() }

        importer.open(wavURL)
        var enteredIter = enteredStream.makeAsyncIterator()
        _ = await enteredIter.next()

        guard let activeTransient = importer.transientItems.first(where: { $0.fileName == "Design standup.wav" }),
              activeTransient.state == .importing,
              activeTransient.title == "Design standup",
              LibraryBadgeCatalog.importingPresentation?.kind == "importing" else {
            singleLatch.release()
            throw NSError(domain: "ImportLifecycleSelfTest", code: 32, userInfo: [NSLocalizedDescriptionKey: "Missing active Importing… card for WAV decode"])
        }

        if proofDir != nil {
            let importingPres = LibraryBadgeCatalog.importingPresentation
            try renderProof(
                "w4-5-importing-card",
                view: VStack(alignment: .leading, spacing: 8) {
                    Text(UXText.text("format.today")).font(.system(size: 11.5, weight: .bold)).foregroundStyle(CassiniTheme.ink2)
                    MeetingCard(isSelected: false) {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 10) {
                                Text(activeTransient.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(CassiniTheme.ink)
                                Spacer(minLength: 2)
                            }
                            HStack(spacing: 6) {
                                Text("14:18").foregroundStyle(CassiniTheme.ink2).monospacedDigit()
                                if let importingPres {
                                    CatalogStatusBadge(presentation: importingPres, isAnimating: false, onAccent: false)
                                }
                                Text(activeTransient.fileName).foregroundStyle(CassiniTheme.ink2)
                            }
                            .font(.system(size: 11.5))
                        }
                    }
                    Spacer()
                }
                .padding(14),
                width: 400,
                height: 180
            )
        }

        singleLatch.release()
        importer.fixtureOnSingleGate = nil
        await importer.waitForShutdown()

        guard !importer.transientItems.contains(where: { $0.fileName == "Design standup.wav" }) else {
            throw NSError(domain: "ImportLifecycleSelfTest", code: 33, userInfo: [NSLocalizedDescriptionKey: "Succeeded WAV import left transient card behind"])
        }

        // 3. Verify batch import of MP3 + M4A + Broken MP3 + Malformed FLAC:
        //    MP3 and M4A import cleanly while Broken MP3 keeps its `Needs attention` card (`W4.6`) even after banner notice dismissal!
        importer.openBatch([mp3URL, m4aURL, brokenMp3URL, flacURL])
        await importer.waitForShutdown()

        let scannedAfterBatch = try LibraryScanner(root: root).scan().meetings
        for expectedTitle in ["Design standup", "Field interview", "Voice memo"] {
            guard let m = scannedAfterBatch.first(where: { $0.title == expectedTitle }),
                  m.state.origin == .received,
                  m.canWriteDown else {
                throw NSError(domain: "ImportLifecycleSelfTest", code: 34, userInfo: [NSLocalizedDescriptionKey: "Missing imported portable meeting '\(expectedTitle)'"])
            }
        }
        guard !scannedAfterBatch.contains(where: { $0.title == "Lossless take" }) else {
            throw NSError(domain: "ImportLifecycleSelfTest", code: 35, userInfo: [NSLocalizedDescriptionKey: "Malformed FLAC file was unexpectedly imported"])
        }

        guard let flacCard = importer.transientItems.first(where: { $0.fileName == "Lossless take.flac" }),
              case .failed(let flacDetail) = flacCard.state, !flacDetail.isEmpty else {
            throw NSError(domain: "ImportLifecycleSelfTest", code: 37, userInfo: [NSLocalizedDescriptionKey: "Malformed FLAC did not retain Needs attention card"])
        }
        guard let failedCard = importer.transientItems.first(where: { $0.fileName == "Damaged recording.mp3" }),
              case .failed(let failureDetail) = failedCard.state,
              !failureDetail.isEmpty,
              LibraryBadgeCatalog.needsAttentionPresentation?.kind == "needsAttention" else {
            throw NSError(domain: "ImportLifecycleSelfTest", code: 36, userInfo: [NSLocalizedDescriptionKey: "Failed batch item did not retain Needs attention card"])
        }

        // Dismissing the bottom notice banner by ID must keep the failed card (`W4.6`) in the list.
        if let noticeID = importer.notice?.id {
            importer.dismissNotice(noticeID)
        }
        guard importer.transientItems.contains(where: { $0.id == failedCard.id }) else {
            throw NSError(domain: "ImportLifecycleSelfTest", code: 37, userInfo: [NSLocalizedDescriptionKey: "Dismissing banner notice wiped Needs attention card"])
        }

        if proofDir != nil {
            let needsAttentionPres = LibraryBadgeCatalog.needsAttentionPresentation
            let receivedPres = CatalogBadgePresentation(kind: "received", text: UXText.text("states.badge.received"), tint: "outline", glyph: "incoming")
            try renderProof(
                "w4-6-failed-card-and-decoded-meetings",
                view: VStack(alignment: .leading, spacing: 8) {
                    Text(UXText.text("format.today")).font(.system(size: 11.5, weight: .bold)).foregroundStyle(CassiniTheme.ink2)
                    MeetingCard(isSelected: false) {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 10) {
                                Text(failedCard.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(CassiniTheme.ink)
                                Spacer(minLength: 2)
                                Text(UXText.text("common.done")).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(CassiniTheme.accentInk)
                            }
                            HStack(spacing: 6) {
                                Text("14:19").foregroundStyle(CassiniTheme.ink2).monospacedDigit()
                                if let needsAttentionPres {
                                    CatalogStatusBadge(presentation: needsAttentionPres, isAnimating: false, onAccent: false)
                                }
                                Text(failureDetail).foregroundStyle(CassiniTheme.ink2).lineLimit(1)
                            }
                            .font(.system(size: 11.5))
                        }
                    }
                    ForEach(["Voice memo", "Field interview", "Design standup"], id: \.self) { title in
                        MeetingCard(isSelected: title == "Voice memo") {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(spacing: 10) {
                                    Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(CassiniTheme.ink)
                                    Spacer(minLength: 2)
                                    Text("0:01").font(.system(size: 11.5)).foregroundStyle(CassiniTheme.ink2).monospacedDigit()
                                }
                                HStack(spacing: 6) {
                                    Text("14:18").foregroundStyle(CassiniTheme.ink2).monospacedDigit()
                                    CatalogStatusBadge(presentation: receivedPres, isAnimating: false, onAccent: false)
                                }
                                .font(.system(size: 11.5))
                            }
                        }
                    }
                    Spacer()
                }
                .padding(14),
                width: 400,
                height: 360
            )
        }

        importer.dismissTransientItem(failedCard.id)
        guard !importer.transientItems.contains(where: { $0.id == failedCard.id }) else {
            throw NSError(domain: "ImportLifecycleSelfTest", code: 38, userInfo: [NSLocalizedDescriptionKey: "Failed card did not dismiss when Done was clicked"])
        }
        importer.dismissNotice()
    }
}
#endif
