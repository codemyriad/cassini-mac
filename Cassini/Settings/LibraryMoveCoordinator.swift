// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import Observation
import CassiniLibrary

@MainActor @Observable final class LibraryMoveCoordinator {
    static let shared = LibraryMoveCoordinator()
    struct FailureGroup: Identifiable { let root: URL; let names: Set<String>; var id: String { root.path } }
    private(set) var busy = false
    var canChoose: Bool { !busy && chooser == nil && !closing && !RecordingOverview.starting && !RecordingOverview.saving }
    var requiresRecordingConfirmation: Bool { RecordingOverview.active }
    var waitingCount: Int { LibraryLocationModel.shared.location.pendingMoves.filter { $0.phase == .pending }.count }
    var failures: [FailureGroup] {
        Dictionary(grouping:LibraryLocationModel.shared.location.pendingMoves.filter { $0.phase == .failed },by:\.sourcePath)
            .map { FailureGroup(root:URL(fileURLWithPath:$0.key),names:Set($0.value.map(\.folderName))) }.sorted { $0.id < $1.id }
    }
    @ObservationIgnored private var task: Task<Void,Never>?
    @ObservationIgnored private var retryTask: Task<Void,Never>?
    @ObservationIgnored private var chooser: NSOpenPanel?
    @ObservationIgnored private var confirmation: NSAlert?
    @ObservationIgnored private var closing = false
    @ObservationIgnored private var observing = false
    private enum Selection { case pending, failed(String?) }
    func start() {
        guard !observing else { return }; observing = true; observeJobs()
        // Upgrade an early local pointer without a journal, if present. No wire
        // or meeting metadata changes are involved.
        let location = LibraryLocationModel.shared
        if location.location.pendingMoves.isEmpty, !location.location.previousPaths.isEmpty {
            let moves = location.roots.dropFirst().flatMap { root in
                ((try? LibraryMove.remaining(in:root)) ?? []).sorted().map { LibraryPendingMove(source:root,folderName:$0) }
            }
            do { try location.replaceMoves(moves) } catch { NSApp.presentError(error); return }
        }
        if waitingCount > 0 { run(destination:nil,selection:.pending) }
    }
    func choose(parent: NSWindow?) {
        guard canChoose else { return }
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.canCreateDirectories = true; panel.allowsMultipleSelection = false
        panel.directoryURL = LibraryLocationModel.shared.roots[0].deletingLastPathComponent(); chooser = panel
        panel.begin { [weak self] response in MainActor.assumeIsolated {
            guard let self else { return }; self.chooser = nil
            guard response == .OK, let url = panel.url, !self.closing else { return }
            let lease = FileAccessLease(url)
            if self.requiresRecordingConfirmation {
                let alert = NSAlert(); self.confirmation = alert; alert.messageText = UXText.text("confirm.moveLibrary.title")
                alert.informativeText = UXText.text("confirm.moveLibrary.body")
                alert.addButton(withTitle:UXText.text("confirm.moveLibrary.primary")).keyEquivalent = "\r"
                alert.addButton(withTitle:UXText.text("common.cancel")).keyEquivalent = "\u{1B}"
                if let parent { alert.beginSheetModal(for:parent) { answer in
                    self.confirmation = nil
                    if answer == .alertFirstButtonReturn && !self.closing { self.run(destination:lease,selection:.pending) }
                } } else {
                    let answer = alert.runModal(); self.confirmation = nil
                    if answer == .alertFirstButtonReturn && !self.closing { self.run(destination:lease,selection:.pending) }
                }
            } else { self.run(destination:lease,selection:.pending) }
        } }
    }
    func retry(root: URL? = nil) { guard !busy else { return }; run(destination:nil,selection:.failed(root?.path)) }
    #if DEBUG
    func moveForTesting(to url: URL, allowingFailures: Bool = false) async throws {
        guard SettingsFixture.id != nil, RecordingFixture.enabled else { throw POSIXError(.EPERM) }
        run(destination:FileAccessLease(url),selection:.pending); await task?.value
        if !allowingFailures && !failures.isEmpty { throw POSIXError(.EIO) }
    }
    #endif
    func dismissForQuit() async {
        let parent = NSApp.keyWindow?.sheetParent ?? NSApp.keyWindow
        SettingsNavigation.shared.capturingShortcut = false
        if let panel = chooser { panel.cancel(nil); chooser = nil }
        if let window = confirmation?.window, let parent = window.sheetParent { parent.endSheet(window,returnCode:.alertSecondButtonReturn) }
        confirmation = nil
        for _ in 0..<40 {
            guard parent?.attachedSheet != nil else { return }; try? await Task.sleep(for:.milliseconds(25))
        }
    }
    func beginShutdown() { closing = true; observing = false; chooser?.cancel(nil); task?.cancel(); retryTask?.cancel() }
    func waitForShutdown() async { await task?.value }
    func maybeRetryDeferred() {
        guard !closing, !busy, retryTask == nil, waitingCount > 0 else { return }
        retryTask = Task {
            do { try await Task.sleep(for:.seconds(2)) } catch { retryTask = nil; return }
            guard !closing, !busy else { retryTask = nil; return }
            let moves = LibraryLocationModel.shared.location.pendingMoves.filter { $0.phase == .pending }
            let held = heldFolders()
            let ready = await Task.detached {
                Dictionary(grouping:moves,by:\.sourcePath).contains { path,work in
                    let root = URL(fileURLWithPath:path), names = Set(work.map(\.folderName))
                    guard let remaining = try? LibraryMove.remaining(in:root),
                          let active = try? LibraryMove.activeOrUnreadable(in:root,only:names) else { return false }
                    return !names.intersection(remaining).subtracting(active).filter { !held.contains(path + "/" + $0) }.isEmpty || !names.subtracting(remaining).isEmpty
                }
            }.value
            retryTask = nil
            if ready { run(destination:nil,selection:.pending) }
        }
    }
    private func observeJobs() {
        guard observing else { return }
        withObservationTracking {
            _ = CaptureCollection.shared.activity
            _ = RecordingController.shared.isRecording; _ = RecordingController.shared.isSaving; _ = TranscriptionQueue.shared.active
        } onChange: { [weak self] in Task { @MainActor in self?.observeJobs(); self?.maybeRetryDeferred() } }
    }
    private func heldFolders() -> Set<String> {
        var held = Set<String>()
        let recorder = RecordingController.shared
        if recorder.isRecording || recorder.isSaving, let directory = recorder.directory { held.insert(LibraryLocation.canonical(directory).path) }
        for value in CaptureCollection.shared.captures.values { held.insert(value.snapshot.directory.standardizedFileURL.path) }
        for root in LibraryLocationModel.shared.roots {
            for id in CaptureActivityStore.shared.snapshot().keys { held.insert(root.appendingPathComponent("Recording-" + id.uuidString.lowercased()).path) }
        }
        if let directory = TranscriptionQueue.shared.active { held.insert(LibraryLocation.canonical(directory).path) }
        return held
    }
    private func run(destination: FileAccessLease?, selection: Selection) {
        guard !busy, !closing else { return }; busy = true
        CaptureCollection.shared.setLibraryMoveBlocked(true)
        task = Task {
            let location = LibraryLocationModel.shared
            do {
                if destination != nil {
                    RecordCoordinator.shared.showingFirst = false
                    MeetingExportCoordinator.shared.cancel(); await MeetingExportCoordinator.shared.waitForShutdown()
                    LibrarySearchModel.shared.close(); MeetingNavigation.shared.back(); SessionPlaybackController.stopAll()
                }
                await RecordingPageModel.flushAll()
                await LibraryImportCoordinator.shared.pauseForMove()
                await TranscriptionQueue.shared.pauseForMove() // preserves the active child/path
                if let destination {
                    try location.choose(destination.url)
                    LibraryStore.shared.reloadLocation() // new recordings/readers use the new root immediately
                }
                let selected = location.location.pendingMoves.filter { move in
                    switch selection {
                    case .pending: return move.phase == .pending
                    case .failed(let root): return move.phase == .failed && (root == nil || root == move.sourcePath)
                    }
                }
                let target = location.roots[0]
                for (path,work) in Dictionary(grouping:selected,by:\.sourcePath).sorted(by:{ $0.key < $1.key }) {
                    try Task.checkCancellation()
                    let source = URL(fileURLWithPath:path), names = Set(work.map(\.folderName)), held = heldFolders()
                    var failed = names, deferred = Set<String>()
                    do {
                        let job = Task.detached(priority:.userInitiated) {
                            let native = Set(names.filter { held.contains(path + "/" + $0) })
                            let excluded = try LibraryMove.activeOrUnreadable(in:source,only:names,shouldCancel:{ Task.isCancelled }).union(native)
                            return try LibraryMove.meetings(from:source,to:target,excluding:excluded,including:names,shouldCancel:{ Task.isCancelled })
                        }
                        let report = try await withTaskCancellationHandler(operation:{ try await job.value },onCancel:{ job.cancel() })
                        failed = Set(report.failed + report.originalsRetained); deferred = Set(report.deferred)
                    } catch is CancellationError { throw CancellationError() }
                    catch { /* The complete source and its explicit failure intent remain. */ }
                    let selectedIDs = Set(work.map(\.id))
                    var next = location.location.pendingMoves.filter { !selectedIDs.contains($0.id) }
                    next += failed.sorted().map { LibraryPendingMove(source:source,folderName:$0,phase:.failed) }
                    next += deferred.sorted().map { LibraryPendingMove(source:source,folderName:$0) }
                    try location.replaceMoves(next)
                }
            } catch is CancellationError {} catch { if !closing { NSApp.presentError(error) } }
            // The journal was durable before moving. Interrupted batches may
            // include already-renamed folders; absent old folders reconcile on
            // restart without touching another meeting or losing old readers.
            LibraryStore.shared.reloadLocation()
            for _ in 0..<200 { if LibraryStore.shared.loaded { break }; try? await Task.sleep(for:.milliseconds(25)) }
            await LibrarySearchModel.shared.reindexAfterMove(LibraryStore.shared.meetings)
            TranscriptionQueue.shared.resumeAfterMove(); LibraryImportCoordinator.shared.resumeAfterMove()
            TranscriptionQueue.shared.consider(LibraryStore.shared.meetings,automatic:!LibraryStore.shared.context.screenshot)
            withExtendedLifetime(destination) {}
            busy = false; CaptureCollection.shared.setLibraryMoveBlocked(false)
            task = nil; maybeRetryDeferred()
        }
    }
}
