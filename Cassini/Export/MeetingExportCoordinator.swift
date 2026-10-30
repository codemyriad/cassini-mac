// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import Darwin
import CassiniLibrary
import CassiniExport
import UniformTypeIdentifiers
import Observation

enum MeetingExportKind: Sendable { case cassini, markdown; var suffix: String { self == .cassini ? "opus" : "md" } }
@MainActor @Observable final class MeetingExportCoordinator {
    static let shared = MeetingExportCoordinator()
    var showing = false
    var kind = MeetingExportKind.cassini { didSet { if kind != oldValue { selectedFile = nil } } }
    struct Receipt: Identifiable {
        let id = UUID()
        let url: URL
        let title: String
        let access: FileAccessLease
    }
    private(set) var receipt: Receipt?
    private(set) var meeting: LibraryMeeting?
    private(set) var estimatedBytes: Int64?
    private(set) var working = false
    private(set) var directory: URL = {
        let home = getpwuid(getuid()).map { URL(fileURLWithPath:String(cString:$0.pointee.pw_dir)) } ?? FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent("Documents")
    }()
    @ObservationIgnored private var selectedFile: FileAccessLease?
    @ObservationIgnored private var task: Task<Void,Never>?
    @ObservationIgnored private var estimateTask: Task<Void,Never>?
    @ObservationIgnored private var presentationTask: Task<Void,Never>?
    @ObservationIgnored private var savePanel: NSSavePanel?
    @ObservationIgnored private var closing = false
    @ObservationIgnored private var chooserGeneration: UInt64 = 0
    var isBusy: Bool { task != nil || presentationTask != nil || savePanel != nil }
    static func canExport(_ meeting: LibraryMeeting?) -> Bool {
        guard !LibraryMoveCoordinator.shared.busy, let meeting, meeting.state.lifecycle == .saved else { return false }
        return !meeting.audioFiles.isEmpty || !meeting.transcriptItems.isEmpty || !meeting.notes.isEmpty
    }
    func show(_ meeting: LibraryMeeting) {
        guard !closing, !isBusy, Self.canExport(meeting) else { return }
        self.meeting = meeting; kind = meeting.audioFiles.isEmpty ? .markdown : .cassini
        selectedFile = nil; receipt = nil
        estimatedBytes = nil; showing = true; estimateTask?.cancel()
        estimateTask = Task {
            let bytes = try? await Task.detached { try MeetingFileExporter.estimatedBytes(meeting) }.value
            guard !Task.isCancelled else { return }; estimatedBytes = bytes
        }
    }
    func chooseDirectory() {
        guard let meeting, !working, !closing, !isBusy else { return }
        presentSavePanel(meeting,kind:kind,exportOnSelection:false)
    }
    func perform() {
        guard let meeting, !working, !closing, !isBusy else { return }
        if let file = selectedFile { start(meeting,kind:kind,file:file) }
        else { presentSavePanel(meeting,kind:kind) }
    }
    func cancel() {
        chooserGeneration &+= 1
        selectedFile = nil
        showing = false; estimateTask?.cancel(); presentationTask?.cancel()
        savePanel?.cancel(nil); task?.cancel()
    }
    func discard(_ folder: URL) async {
        guard meeting?.folder == folder else { return }
        cancel(); await waitForShutdown()
        meeting = nil; estimatedBytes = nil
    }
    func beginShutdown() { closing = true; cancel() }
    func waitForShutdown() async { await presentationTask?.value; await task?.value }
    func dismissForQuit() async {
        let parent = NSApp.keyWindow?.sheetParent ?? NSApp.mainWindow
        cancel()
        for _ in 0..<40 {
            guard parent?.attachedSheet != nil else { return }
            try? await Task.sleep(for:.milliseconds(25))
        }
    }
    func clearReceipt(_ id: UUID) { if receipt?.id == id { receipt = nil } }
    func revealReceipt() {
        guard let receipt else { return }
        NSWorkspace.shared.activateFileViewerSelecting([receipt.url])
    }
    private func presentSavePanel(_ meeting: LibraryMeeting, kind: MeetingExportKind, exportOnSelection: Bool = true) {
        chooserGeneration &+= 1
        let generation = chooserGeneration
        let parent = NSApp.keyWindow?.sheetParent ?? NSApp.mainWindow
        showing = false
        presentationTask = Task {
            defer { presentationTask = nil }
            for _ in 0..<40 {
                guard parent?.attachedSheet != nil else { break }
                do { try await Task.sleep(for:.milliseconds(25)) } catch { return }
            }
            guard !closing, !Task.isCancelled else { return }
            let panel = NSSavePanel(); panel.directoryURL = directory
            panel.nameFieldStringValue = MeetingMarkdown.filename(title:meeting.title ?? UXText.text("library.untitled"),extension:kind.suffix)
            panel.allowedContentTypes = [kind == .cassini ? .oggAudio : (UTType(filenameExtension:"md") ?? .plainText)]
            panel.canCreateDirectories = true; savePanel = panel
            let complete: (NSApplication.ModalResponse) -> Void = { [self] response in MainActor.assumeIsolated {
                self.savePanel = nil
                guard !self.closing, self.chooserGeneration == generation else { return }
                if response == .OK, let url = panel.url {
                    let file = FileAccessLease(url)
                    self.directory = url.deletingLastPathComponent()
                    self.selectedFile = file
                    if exportOnSelection { self.start(meeting,kind:kind,file:file) }
                    else { self.resumeSheet(parent:parent) }
                } else { self.resumeSheet(parent:parent) }
            } }
            if let parent, parent.attachedSheet == nil { panel.beginSheetModal(for:parent,completionHandler:complete) }
            else { panel.begin(completionHandler:complete) }
        }
    }
    private func resumeSheet(parent: NSWindow?) {
        presentationTask = Task {
            defer { presentationTask = nil }
            for _ in 0..<40 {
                guard parent?.attachedSheet != nil else { break }
                do { try await Task.sleep(for:.milliseconds(25)) } catch { return }
            }
            guard !closing, !Task.isCancelled, parent?.attachedSheet == nil, parent?.isVisible == true else { return }
            showing = true
        }
    }
    private func start(_ meeting: LibraryMeeting, kind: MeetingExportKind, file: FileAccessLease) {
        guard task == nil, !closing else { return }; working = true
        task = Task {
            do {
                let fallbackTitle = UXText.text("library.untitled")
                let work = Task.detached(priority:.userInitiated) { [file] in
                    defer { withExtendedLifetime(file) {} }
                    try Task.checkCancellation()
                    let artifact: ExportArtifact
                    if kind == .markdown { artifact = try MeetingFileExporter.markdown(meeting,timeZone:.current) }
                    else {
                        let assets = meeting.state.origin == .own ? try OpusAssets.bundled(app:Bundle.main.bundleURL) : nil
                        artifact = try MeetingFileExporter.cassini(meeting,assets:assets,shouldCancel:{ Task.isCancelled })
                    }
                    try Task.checkCancellation()
                    try ExportDestination.selectedFile(artifact,url:file.url,shouldCancel:{ Task.isCancelled })
                }
                try await withTaskCancellationHandler(operation:{ try await work.value },onCancel:{ work.cancel() })
                showing = false
                receipt = Receipt(url:file.url,title:meeting.title ?? fallbackTitle,access:file)
            } catch is CancellationError {} catch { if !closing { NSApp.presentError(error) } }
            working = false; task = nil
        }
    }
}
