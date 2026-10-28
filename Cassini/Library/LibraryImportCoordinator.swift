// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import CassiniLibrary
import Observation

/// Serial imports keep the selected file's security scope through off-main copy,
/// hash and validation. Quit cancels and waits for ordinary cleanup.
@MainActor @Observable final class LibraryImportCoordinator {
    static let shared = LibraryImportCoordinator()
    private struct Request { let lease: FileAccessLease; let key: String; let retaining: AnyObject? }
    @ObservationIgnored private var pending: [Request] = []
    @ObservationIgnored private var requestedTranscription = Set<String>()
    @ObservationIgnored private var scheduled = Set<String>()
    @ObservationIgnored private var task: Task<Void,Never>?
    @ObservationIgnored private var closing = false
    @ObservationIgnored private var paused = false
    var isBusy: Bool { task != nil || !pending.isEmpty }
    func open(_ url: URL, writingDown: Bool = false, retaining: AnyObject? = nil) {
        guard !closing, url.isFileURL else { return }
        guard LibraryLocationModel.shared.available else {
            NSApp.presentError(NSError(domain:"CassiniLibraryLocation",code:1,userInfo:[NSLocalizedDescriptionKey:LibraryLocationModel.shared.problem ?? POSIXError(.EACCES).localizedDescription])); return
        }
        let key = url.standardizedFileURL.path
        if writingDown { requestedTranscription.insert(key) }
        guard scheduled.insert(key).inserted else { return }
        pending.append(Request(lease:FileAccessLease(url),key:key,retaining:retaining))
        MeetingNavigation.shared.openLibrary?(); startNext()
    }
    func beginShutdown() { closing = true; pending.removeAll(); requestedTranscription.removeAll(); task?.cancel() }
    func waitForShutdown() async { await task?.value }
    func pauseForMove() async { paused = true; task?.cancel(); await task?.value }
    func resumeAfterMove() { guard !closing else { return }; paused = false; startNext() }
    private func startNext() {
        guard !closing, !paused, task == nil, !pending.isEmpty else { return }
        let request = pending.removeFirst(), roots = LibraryLocationModel.shared.roots
        let root = roots[0]
        let lease = request.lease
        task = Task {
            var requeued = false
            defer {
                if !requeued { scheduled.remove(request.key); requestedTranscription.remove(request.key) }
                withExtendedLifetime(request.retaining) {}
            }
            do {
                let work = Task.detached(priority:.userInitiated) { [lease] in
                    defer { withExtendedLifetime(lease) {} }
                    try Task.checkCancellation()
                    return try LibraryImport.copy(lease.url,into:root,additionalRoots:Array(roots.dropFirst()),shouldCancel:{ Task.isCancelled })
                }
                let meeting = try await withTaskCancellationHandler(operation:{ try await work.value },onCancel:{ work.cancel() })
                try Task.checkCancellation()
                LibrarySearchModel.shared.close()
                MeetingNavigation.shared.back()
                LibraryStore.shared.selectImported(meeting)
                if requestedTranscription.remove(request.key) != nil {
                    if meeting.canWriteDown { TranscriptionQueue.shared.enqueue(meeting,retry:meeting.state.transcript == .failed) }
                    MeetingNavigation.shared.open(meeting)
                }
                MeetingNavigation.shared.openLibrary?(); NSApp.activate(ignoringOtherApps:true)
            } catch is CancellationError {
                if paused && !closing { pending.insert(request,at:0); requeued = true }
            } catch { if !closing { NSApp.presentError(error) } }
            task = nil; startNext()
        }
    }
}
