// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import Darwin
import CassiniLibrary
import CassiniExport
import UniformTypeIdentifiers
import Observation

@MainActor @Observable final class BulkZipExportCoordinator {
    static let shared = BulkZipExportCoordinator()

    struct Progress: Equatable {
        let done: Int
        let total: Int
    }

    struct Receipt: Identifiable {
        let id = UUID()
        let url: URL
        let count: Int
        let access: FileAccessLease
    }

    private(set) var busy = false
    private(set) var progress: Progress?
    private(set) var receipt: Receipt?
    private(set) var directory: URL = {
        let home = getpwuid(getuid()).map { URL(fileURLWithPath: String(cString: $0.pointee.pw_dir)) }
            ?? FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent("Documents")
    }()

    @ObservationIgnored private var task: Task<Void, Never>? { didSet { refreshBusy() } }
    @ObservationIgnored private var presentationTask: Task<Void, Never>? { didSet { refreshBusy() } }
    @ObservationIgnored private var savePanel: NSSavePanel? { didSet { refreshBusy() } }
    @ObservationIgnored private var closing = false
    @ObservationIgnored private var chooserGeneration: UInt64 = 0
    @ObservationIgnored private var runToken: UInt64 = 0
    #if DEBUG
    @ObservationIgnored var fixtureOnProgressGate: (@Sendable (Int, Int) -> Void)?
    #endif

    private func refreshBusy() {
        let next = task != nil || presentationTask != nil || savePanel != nil
        if busy != next { busy = next }
    }

    private final class ProgressCoalescer: @unchecked Sendable {
        private let lock = NSLock()
        private var latest: (done: Int, total: Int)?
        private var scheduled = false

        func enqueue(done: Int, total: Int) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            latest = (done, total)
            guard !scheduled else { return false }
            scheduled = true
            return true
        }

        func consume() -> (done: Int, total: Int)? {
            lock.lock()
            defer { lock.unlock() }
            scheduled = false
            return latest
        }
    }

    var isBusy: Bool { busy }

    var hasSelection: Bool {
        MeetingNavigation.shared.detail == nil &&
        !LibrarySearchModel.shared.visible &&
        !LibraryStore.shared.selectedKeys.isEmpty
    }

    var canExportSelected: Bool {
        guard !closing, !isBusy, !MeetingExportCoordinator.shared.isBusy, !LibraryMoveCoordinator.shared.busy, hasSelection else {
            return false
        }
        return hasAnyInMemoryExportable(in: LibraryStore.shared.selectedMeetings)
    }

    var canExportAll: Bool {
        guard !closing, !isBusy, !MeetingExportCoordinator.shared.isBusy, !LibraryMoveCoordinator.shared.busy else {
            return false
        }
        return hasAnyInMemoryExportable(in: LibraryStore.shared.meetings)
    }

    func exportSelected() {
        guard canExportSelected else { return }
        let selected = inMemoryExportableMeetings(from: LibraryStore.shared.selectedMeetings)
        guard !selected.isEmpty else { return }
        presentSavePanel(for: selected)
    }

    func exportAll() {
        guard canExportAll else { return }
        let all = inMemoryExportableMeetings(from: LibraryStore.shared.meetings)
        guard !all.isEmpty else { return }
        presentSavePanel(for: all)
    }

    func cancel() {
        chooserGeneration &+= 1
        runToken &+= 1
        progress = nil
        presentationTask?.cancel()
        savePanel?.cancel(nil)
        task?.cancel()
    }

    func beginShutdown() {
        closing = true
        cancel()
    }

    func waitForShutdown() async {
        await presentationTask?.value
        await task?.value
    }

    func dismissForQuit() async {
        let parent = NSApp.keyWindow?.sheetParent ?? NSApp.mainWindow
        cancel()
        for _ in 0..<40 {
            guard parent?.attachedSheet != nil else { return }
            try? await Task.sleep(for: .milliseconds(25))
        }
    }

    func clearReceipt(_ id: UUID) {
        if receipt?.id == id {
            receipt = nil
        }
    }

    func revealReceipt() {
        guard let receipt else { return }
        NSWorkspace.shared.activateFileViewerSelecting([receipt.url])
    }

    #if DEBUG
    func startExportForTesting(_ meetings: [LibraryMeeting], to destinationURL: URL) {
        startExport(meetings, file: FileAccessLease(destinationURL))
    }
    #endif

    /// Pure in-memory check (zero filesystem syscalls on `@MainActor`).
    private func hasAnyInMemoryExportable(in meetings: [LibraryMeeting]) -> Bool {
        let liveIDs = Set(CaptureActivityStore.shared.snapshot().keys)
        let recorder = RecordingController.shared
        let nativeLivePath = (recorder.isRecording || recorder.isSaving) ? recorder.directory?.standardizedFileURL.path : nil
        let browserLivePaths = Set(CaptureCollection.shared.captures.values.map { $0.snapshot.directory.standardizedFileURL.path })
        return meetings.contains { meeting in
            guard meeting.state.lifecycle == .saved,
                  meeting.state.audioAvailable != false,
                  !meeting.audioFiles.isEmpty,
                  !liveIDs.contains(meeting.id) else {
                return false
            }
            let folderPath = meeting.folder.standardizedFileURL.path
            return folderPath != nativeLivePath && !browserLivePaths.contains(folderPath)
        }
    }

    private func inMemoryExportableMeetings(from meetings: [LibraryMeeting]) -> [LibraryMeeting] {
        let liveIDs = Set(CaptureActivityStore.shared.snapshot().keys)
        let recorder = RecordingController.shared
        let nativeLivePath = (recorder.isRecording || recorder.isSaving) ? recorder.directory?.standardizedFileURL.path : nil
        let browserLivePaths = Set(CaptureCollection.shared.captures.values.map { $0.snapshot.directory.standardizedFileURL.path })
        return meetings.filter { meeting in
            guard meeting.state.lifecycle == .saved,
                  meeting.state.audioAvailable != false,
                  !meeting.audioFiles.isEmpty,
                  !liveIDs.contains(meeting.id) else {
                return false
            }
            let folderPath = meeting.folder.standardizedFileURL.path
            return folderPath != nativeLivePath && !browserLivePaths.contains(folderPath)
        }
    }

    private nonisolated static func liveFolderPathsSnapshot(roots: [URL], nativeRecordingDir: URL?, browserCaptureDirs: [URL]) -> Set<String> {
        var paths = Set<String>()
        if let nativeRecordingDir {
            paths.insert(LibraryLocation.canonical(nativeRecordingDir).path)
        }
        for dir in browserCaptureDirs {
            paths.insert(LibraryLocation.canonical(dir).path)
        }
        for root in roots {
            for id in CaptureActivityStore.shared.snapshot().keys {
                let candidate = root.appendingPathComponent("Recording-" + id.uuidString.lowercased())
                paths.insert(LibraryLocation.canonical(candidate).path)
            }
        }
        return paths
    }

    private func defaultArchiveFilename() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        let stamp = formatter.string(from: Date())
        return MeetingMarkdown.filename(title: "\(UXText.text("app.name")) \(stamp)", extension: "zip")
    }

    private func presentSavePanel(for meetings: [LibraryMeeting]) {
        chooserGeneration &+= 1
        let generation = chooserGeneration
        let parent = NSApp.keyWindow?.sheetParent ?? NSApp.mainWindow
        presentationTask = Task {
            defer { presentationTask = nil }
            for _ in 0..<40 {
                guard parent?.attachedSheet != nil else { break }
                do { try await Task.sleep(for: .milliseconds(25)) } catch { return }
            }
            guard !closing, !Task.isCancelled else { return }
            let panel = NSSavePanel()
            panel.directoryURL = directory
            panel.nameFieldStringValue = defaultArchiveFilename()
            panel.allowedContentTypes = [.zip]
            panel.canCreateDirectories = true
            savePanel = panel
            let complete: (NSApplication.ModalResponse) -> Void = { [self] response in
                MainActor.assumeIsolated {
                    self.savePanel = nil
                    guard !self.closing, self.chooserGeneration == generation else { return }
                    if response == .OK, let url = panel.url {
                        let file = FileAccessLease(url)
                        self.directory = url.deletingLastPathComponent()
                        self.startExport(meetings, file: file)
                    }
                }
            }
            if let parent, parent.attachedSheet == nil {
                panel.beginSheetModal(for: parent, completionHandler: complete)
            } else {
                panel.begin(completionHandler: complete)
            }
        }
    }

    private func updateProgress(done: Int, total: Int, token: UInt64) {
        guard runToken == token, !closing, total > 0 else { return }
        let next = Progress(done: max(1, min(done, total)), total: total)
        if progress != next {
            progress = next
        }
    }

    private func startExport(_ meetings: [LibraryMeeting], file: FileAccessLease) {
        guard task == nil, !closing else { return }
        MeetingExportCoordinator.shared.clearReceiptIfAny()
        receipt = nil
        runToken &+= 1
        let token = runToken
        progress = Progress(done: 1, total: max(1, meetings.count))

        let fallbackUntitled = UXText.text("library.untitled")
        let bundleURL = Bundle.main.bundleURL
        let roots = LibraryLocationModel.shared.roots
        let recorder = RecordingController.shared
        let nativeDir = (recorder.isRecording || recorder.isSaving) ? recorder.directory : nil
        let browserDirs = CaptureCollection.shared.captures.values.map(\.snapshot.directory)
        let coalescer = ProgressCoalescer()
        #if DEBUG
        let progressGate = fixtureOnProgressGate
        #endif

        task = Task {
            do {
                let work = Task.detached(priority: .userInitiated) { [file, coalescer] () throws -> Int in
                    defer { withExtendedLifetime(file) {} }
                    try Task.checkCancellation()
                    let canonicalRoots = roots.map { LibraryLocation.canonical($0) }
                    let initialLivePaths = Self.liveFolderPathsSnapshot(
                        roots: canonicalRoots,
                        nativeRecordingDir: nativeDir,
                        browserCaptureDirs: browserDirs
                    )
                    let needsEncoder = meetings.contains { $0.state.origin == .own }
                    let assets = needsEncoder ? try OpusAssets.bundled(app: bundleURL) : nil
                    return try BulkZipExporter.export(
                        meetings,
                        to: file.url,
                        assets: assets,
                        untitledFallback: fallbackUntitled,
                        timeZone: .current,
                        isLiveFolder: { folder in
                            let canonical = LibraryLocation.canonical(folder).path
                            if initialLivePaths.contains(canonical) { return true }
                            let activeIDs = CaptureActivityStore.shared.snapshot().keys
                            for root in canonicalRoots {
                                for id in activeIDs {
                                    let live = root.appendingPathComponent("Recording-" + id.uuidString.lowercased()).path
                                    if live == canonical { return true }
                                }
                            }
                            return false
                        },
                        onProgress: { done, total in
                            if coalescer.enqueue(done: done, total: total) {
                                Task { @MainActor in
                                    if let latest = coalescer.consume() {
                                        BulkZipExportCoordinator.shared.updateProgress(done: latest.done, total: latest.total, token: token)
                                    }
                                }
                            }
                            #if DEBUG
                            progressGate?(done, total)
                            #endif
                        },
                        shouldCancel: { Task.isCancelled }
                    )
                }
                let exportedCount = try await withTaskCancellationHandler(
                    operation: { try await work.value },
                    onCancel: { work.cancel() }
                )

                try Task.checkCancellation()
                progress = nil
                receipt = Receipt(url: file.url, count: exportedCount, access: file)
            } catch is CancellationError {
                if runToken == token { progress = nil }
            } catch {
                if runToken == token { progress = nil }
                if !closing { NSApp.presentError(error) }
            }
            task = nil
        }
    }
}
