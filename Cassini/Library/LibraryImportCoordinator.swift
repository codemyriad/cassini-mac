// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import CassiniLibrary
import Observation

/// Serial imports keep the selected files' security scope through off-main copy,
/// archive extraction, hash and validation. Quit cancels and waits for ordinary cleanup.
@MainActor @Observable final class LibraryImportCoordinator {
    static let shared = LibraryImportCoordinator()

    struct Progress: Equatable {
        let done: Int
        let total: Int
    }

    struct Notice: Identifiable, Equatable {
        let id = UUID()
        let message: String
        let isWarning: Bool
        let autoDismiss: Bool
    }

    private struct SingleRequest {
        let lease: FileAccessLease
        let key: String
        let retaining: AnyObject?
    }

    private enum Job {
        case single(SingleRequest)
        case batch([FileAccessLease])
    }

    private final class SummaryBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value = LibraryImportSummary()
        private var latestProgress: (done: Int, total: Int)?
        private var progressScheduled = false

        func update(_ summary: LibraryImportSummary) {
            lock.lock(); value = summary; lock.unlock()
        }

        func snapshot() -> LibraryImportSummary {
            lock.lock(); defer { lock.unlock() }
            return value
        }

        func enqueueProgress(done: Int, total: Int) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            latestProgress = (done, total)
            guard !progressScheduled else { return false }
            progressScheduled = true
            return true
        }

        func consumeProgress() -> (done: Int, total: Int)? {
            lock.lock()
            defer { lock.unlock() }
            progressScheduled = false
            return latestProgress
        }
    }

    private(set) var progress: Progress?
    private(set) var notice: Notice? {
        didSet {
            noticeExpiryTask?.cancel()
            if let current = notice, current.autoDismiss {
                let id = current.id
                noticeExpiryTask = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(10)) } catch { return }
                    self?.dismissNotice(id)
                }
            } else {
                noticeExpiryTask = nil
            }
        }
    }

    @ObservationIgnored private var pending: [Job] = []
    @ObservationIgnored private var requestedTranscription = Set<String>()
    @ObservationIgnored private var scheduled = Set<String>()
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var noticeExpiryTask: Task<Void, Never>?
    @ObservationIgnored private var closing = false
    @ObservationIgnored private var paused = false
    @ObservationIgnored private var cancellingCurrent = false
    @ObservationIgnored private var runToken: UInt64 = 0
    #if DEBUG
    @ObservationIgnored var fixtureOnProgressGate: (@Sendable (Int, Int) -> Void)?
    #endif

    var isBusy: Bool { task != nil || !pending.isEmpty }

    func open(_ url: URL, writingDown: Bool = false, retaining: AnyObject? = nil) {
        guard !closing, url.isFileURL else { return }
        if !writingDown && url.pathExtension.lowercased() == "zip" {
            openBatch([url])
            return
        }
        guard LibraryLocationModel.shared.available else {
            NSApp.presentError(NSError(
                domain: "CassiniLibraryLocation",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: LibraryLocationModel.shared.problem ?? POSIXError(.EACCES).localizedDescription]
            ))
            return
        }
        let key = url.standardizedFileURL.path
        if writingDown { requestedTranscription.insert(key) }
        guard scheduled.insert(key).inserted else { return }
        pending.append(.single(SingleRequest(lease: FileAccessLease(url), key: key, retaining: retaining)))
        MeetingNavigation.shared.openLibrary?()
        startNext()
    }

    func openBatch(_ urls: [URL]) {
        let fileURLs = urls.filter { $0.isFileURL && !$0.hasDirectoryPath }
        guard !closing, !fileURLs.isEmpty else { return }
        if fileURLs.count == 1 {
            let ext = fileURLs[0].pathExtension.lowercased()
            if ext != "zip" && LibraryImport.supportedAudioExtensions.contains(ext) {
                open(fileURLs[0])
                return
            }
        }
        guard LibraryLocationModel.shared.available else {
            NSApp.presentError(NSError(
                domain: "CassiniLibraryLocation",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: LibraryLocationModel.shared.problem ?? POSIXError(.EACCES).localizedDescription]
            ))
            return
        }
        let leases = fileURLs.map(FileAccessLease.init)
        pending.append(.batch(leases))
        MeetingNavigation.shared.openLibrary?()
        startNext()
    }

    func cancelCurrentRun() {
        guard task != nil else { return }
        cancellingCurrent = true
        task?.cancel()
    }

    func dismissNotice(_ id: UUID? = nil) {
        if id == nil || notice?.id == id {
            notice = nil
        }
    }

    func beginShutdown() {
        closing = true
        noticeExpiryTask?.cancel()
        noticeExpiryTask = nil
        pending.removeAll()
        requestedTranscription.removeAll()
        progress = nil
        task?.cancel()
    }

    func waitForShutdown() async {
        while let current = task {
            await current.value
        }
    }

    #if DEBUG
    func waitForFixtureImport() async {
        guard RecordingFixture.enabled else { return }
        await waitForShutdown()
    }
    #endif

    func pauseForMove() async {
        paused = true
        task?.cancel()
        await task?.value
    }

    func resumeAfterMove() {
        guard !closing else { return }
        paused = false
        startNext()
    }

    private func updateProgress(done: Int, total: Int, token: UInt64) {
        guard runToken == token, !closing, !cancellingCurrent, total > 0 else { return }
        let next = Progress(done: max(1, min(done, total)), total: total)
        if progress != next {
            progress = next
        }
    }

    private func startNext() {
        guard !closing, !paused, task == nil, !pending.isEmpty else { return }
        let job = pending.removeFirst()
        let roots = LibraryLocationModel.shared.roots
        let root = roots[0]

        switch job {
        case .single(let request):
            let lease = request.lease
            cancellingCurrent = false
            task = Task {
                var requeued = false
                defer {
                    if !requeued {
                        scheduled.remove(request.key)
                        requestedTranscription.remove(request.key)
                    }
                    withExtendedLifetime(request.retaining) {}
                }
                do {
                    let work = Task.detached(priority: .userInitiated) { [lease] in
                        defer { withExtendedLifetime(lease) {} }
                        try Task.checkCancellation()
                        return try LibraryImport.copy(
                            lease.url,
                            into: root,
                            additionalRoots: Array(roots.dropFirst()),
                            shouldCancel: { Task.isCancelled }
                        )
                    }
                    let meeting = try await withTaskCancellationHandler(
                        operation: { try await work.value },
                        onCancel: { work.cancel() }
                    )
                    try Task.checkCancellation()
                    LibrarySearchModel.shared.close()
                    MeetingNavigation.shared.back()
                    let displayed = LibraryStore.shared.selectImported(meeting)
                    if requestedTranscription.remove(request.key) != nil {
                        if meeting.canWriteDown {
                            TranscriptionQueue.shared.enqueue(displayed, retry: displayed.state.transcript == .failed)
                        }
                        MeetingNavigation.shared.open(displayed)
                    }
                    MeetingNavigation.shared.openLibrary?()
                    NSApp.activate(ignoringOtherApps: true)
                } catch is CancellationError {
                    if paused && !closing && !cancellingCurrent {
                        pending.insert(.single(request), at: 0)
                        requeued = true
                    }
                } catch {
                    if !closing { NSApp.presentError(error) }
                }
                cancellingCurrent = false
                task = nil
                startNext()
            }

        case .batch(let leases):
            runToken &+= 1
            let token = runToken
            cancellingCurrent = false
            notice = nil
            progress = Progress(done: 1, total: max(1, leases.count))
            let box = SummaryBox()
            #if DEBUG
            let progressGate = fixtureOnProgressGate
            #endif

            task = Task {
                do {
                    let urls = leases.map(\.url)
                    let additional = Array(roots.dropFirst())
                    let work = Task.detached(priority: .userInitiated) { [leases, box] () throws -> LibraryImportSummary in
                        defer { withExtendedLifetime(leases) {} }
                        try Task.checkCancellation()
                        var running = LibraryImportSummary()
                        let result = try LibraryBatchImport.importURLs(
                            urls,
                            into: root,
                            additionalRoots: additional,
                            summary: &running,
                            onPartialSummary: { partial in
                                box.update(partial)
                            },
                            onProgress: { done, total in
                                if box.enqueueProgress(done: done, total: total) {
                                    Task { @MainActor in
                                        if let latest = box.consumeProgress() {
                                            LibraryImportCoordinator.shared.updateProgress(done: latest.done, total: latest.total, token: token)
                                        }
                                    }
                                }
                                #if DEBUG
                                progressGate?(done, total)
                                #endif
                            },
                            shouldCancel: {
                                Task.isCancelled
                            }
                        )
                        box.update(result)
                        return result
                    }

                    let summary: LibraryImportSummary
                    do {
                        summary = try await withTaskCancellationHandler(
                            operation: { try await work.value },
                            onCancel: { work.cancel() }
                        )
                    } catch {
                        // Capture partial summary even on cancel.
                        throw error
                    }

                    try Task.checkCancellation()
                    progress = nil
                    if let selected = summary.lastSelected {
                        LibrarySearchModel.shared.close()
                        MeetingNavigation.shared.back()
                        _ = LibraryStore.shared.selectImported(selected)
                    }
                    if summary.imported > 0 {
                        LibraryStore.shared.refresh()
                    }
                    MeetingNavigation.shared.openLibrary?()
                    NSApp.activate(ignoringOtherApps: true)

                    let message = summary.rendered(language: UXText.language, locale: UXText.locale)
                    if !message.isEmpty {
                        let warning = summary.failed > 0
                        notice = Notice(
                            message: message,
                            isWarning: warning,
                            autoDismiss: !warning && summary.unsupported == 0
                        )
                    }
                } catch is CancellationError {
                    progress = nil
                    if paused && !closing && !cancellingCurrent {
                        pending.insert(.batch(leases), at: 0)
                    } else if cancellingCurrent && !closing {
                        var partial = box.snapshot()
                        partial.cancelled = true
                        if partial.imported > 0 {
                            if let selected = partial.lastSelected {
                                _ = LibraryStore.shared.selectImported(selected)
                            }
                            LibraryStore.shared.refresh()
                        }
                        let message = partial.rendered(language: UXText.language, locale: UXText.locale)
                        if !message.isEmpty {
                            notice = Notice(message: message, isWarning: false, autoDismiss: false)
                        }
                    }
                } catch let failure as ZipArchiveFailure {
                    progress = nil
                    if !closing {
                        notice = Notice(
                            message: UXText.text(failure.localizationID),
                            isWarning: true,
                            autoDismiss: false
                        )
                    }
                } catch {
                    progress = nil
                    if !closing { NSApp.presentError(error) }
                }
                cancellingCurrent = false
                task = nil
                startNext()
            }
        }
    }
}
