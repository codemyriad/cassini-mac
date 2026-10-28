// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import CassiniLibrary
import Observation

/// Serial imports keep the selected file's security scope through off-main copy,
/// hash and validation. Quit cancels and waits for ordinary cleanup.
@MainActor @Observable final class LibraryImportCoordinator {
    static let shared = LibraryImportCoordinator()
    @ObservationIgnored private var pending: [FileAccessLease] = []
    @ObservationIgnored private var task: Task<Void,Never>?
    @ObservationIgnored private var closing = false
    var isBusy: Bool { task != nil || !pending.isEmpty }
    func open(_ url: URL) {
        guard !closing, url.isFileURL else { return }
        pending.append(FileAccessLease(url)); MeetingNavigation.shared.openLibrary?(); startNext()
    }
    func beginShutdown() { closing = true; pending.removeAll(); task?.cancel() }
    func waitForShutdown() async { await task?.value }
    private func startNext() {
        guard !closing, task == nil, !pending.isEmpty else { return }
        let lease = pending.removeFirst(), root = LibraryLaunchContext.current.root
        task = Task {
            do {
                let work = Task.detached(priority:.userInitiated) { [lease] in
                    defer { withExtendedLifetime(lease) {} }
                    try Task.checkCancellation()
                    return try LibraryImport.copy(lease.url,into:root,shouldCancel:{ Task.isCancelled })
                }
                let meeting = try await withTaskCancellationHandler(operation:{ try await work.value },onCancel:{ work.cancel() })
                try Task.checkCancellation()
                LibrarySearchModel.shared.close()
                MeetingNavigation.shared.back()
                LibraryStore.shared.selectImported(meeting)
                MeetingNavigation.shared.openLibrary?(); NSApp.activate(ignoringOtherApps:true)
            } catch is CancellationError {} catch { if !closing { NSApp.presentError(error) } }
            task = nil; startNext()
        }
    }
}
