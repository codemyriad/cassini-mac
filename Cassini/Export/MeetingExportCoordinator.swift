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
    var kind = MeetingExportKind.cassini
    private(set) var meeting: LibraryMeeting?
    private(set) var estimatedBytes: Int64?
    private(set) var working = false
    private(set) var directory: URL = {
        let home = getpwuid(getuid()).map { URL(fileURLWithPath:String(cString:$0.pointee.pw_dir)) } ?? FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent("Documents")
    }()
    @ObservationIgnored private var directoryAccess: FileAccessLease?
    @ObservationIgnored private var task: Task<Void,Never>?
    @ObservationIgnored private var estimateTask: Task<Void,Never>?
    @ObservationIgnored private var presentationTask: Task<Void,Never>?
    @ObservationIgnored private var openPanel: NSOpenPanel?
    @ObservationIgnored private var savePanel: NSSavePanel?
    @ObservationIgnored private var closing = false
    var isBusy: Bool { task != nil || presentationTask != nil || savePanel != nil || openPanel != nil }
    static func canExport(_ meeting: LibraryMeeting?) -> Bool {
        guard !LibraryMoveCoordinator.shared.busy, let meeting, meeting.state.lifecycle == .saved else { return false }
        return !meeting.audioFiles.isEmpty || !meeting.transcriptItems.isEmpty || !meeting.notes.isEmpty
    }
    func show(_ meeting: LibraryMeeting) {
        guard !closing, !isBusy, Self.canExport(meeting) else { return }
        self.meeting = meeting; kind = meeting.audioFiles.isEmpty ? .markdown : .cassini
        estimatedBytes = nil; showing = true; estimateTask?.cancel()
        estimateTask = Task {
            let bytes = try? await Task.detached { try MeetingFileExporter.estimatedBytes(meeting) }.value
            guard !Task.isCancelled else { return }; estimatedBytes = bytes
        }
    }
    func chooseDirectory() {
        guard !working, !closing else { return }
        guard openPanel == nil else { openPanel?.makeKeyAndOrderFront(nil); return }
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false; panel.directoryURL = directory; openPanel = panel
        panel.begin { [weak self] response in MainActor.assumeIsolated {
            guard let self else { return }; self.openPanel = nil
            if response == .OK, let url = panel.url { self.directoryAccess = FileAccessLease(url); self.directory = url }
        } }
    }
    func perform() {
        guard let meeting, !working, !closing, !isBusy else { return }
        if let access = directoryAccess { start(meeting,kind:kind,folder:access,file:nil) }
        else { presentSavePanel(meeting,kind:kind) }
    }
    func cancel() {
        showing = false; estimateTask?.cancel(); presentationTask?.cancel()
        openPanel?.cancel(nil); savePanel?.cancel(nil); task?.cancel()
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
    private func presentSavePanel(_ meeting: LibraryMeeting, kind: MeetingExportKind) {
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
                if response == .OK, let url = panel.url, !self.closing { self.start(meeting,kind:kind,folder:nil,file:FileAccessLease(url)) }
            } }
            if let parent, parent.attachedSheet == nil { panel.beginSheetModal(for:parent,completionHandler:complete) }
            else { panel.begin(completionHandler:complete) }
        }
    }
    private func start(_ meeting: LibraryMeeting, kind: MeetingExportKind, folder: FileAccessLease?, file: FileAccessLease?) {
        guard task == nil, !closing else { return }; working = true
        task = Task {
            do {
                let fallbackTitle = UXText.text("library.untitled")
                let work = Task.detached(priority:.userInitiated) { [folder,file] in
                    defer { withExtendedLifetime((folder,file)) {} }
                    try Task.checkCancellation()
                    let artifact: ExportArtifact
                    if kind == .markdown { artifact = try MeetingFileExporter.markdown(meeting,timeZone:.current) }
                    else {
                        let assets = meeting.state.origin == .own ? try OpusAssets.bundled(app:Bundle.main.bundleURL) : nil
                        artifact = try MeetingFileExporter.cassini(meeting,assets:assets,shouldCancel:{ Task.isCancelled })
                    }
                    try Task.checkCancellation()
                    if let folder { _ = try ExportDestination.folder(artifact,directory:folder.url,title:meeting.title ?? fallbackTitle,extension:kind.suffix,shouldCancel:{ Task.isCancelled }) }
                    else if let file { try ExportDestination.selectedFile(artifact,url:file.url,shouldCancel:{ Task.isCancelled }) }
                }
                try await withTaskCancellationHandler(operation:{ try await work.value },onCancel:{ work.cancel() })
                showing = false
            } catch is CancellationError {} catch { if !closing { NSApp.presentError(error) } }
            working = false; task = nil
        }
    }
}
