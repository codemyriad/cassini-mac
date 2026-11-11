// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import Observation
import CassiniKit
import CassiniLibrary
import CassiniExport
import UniformTypeIdentifiers

/// Scope leases outlive detached work; Quit and Library moves cancel and join it.
@MainActor @Observable final class LibraryBulkTransfer {
    static let shared=LibraryBulkTransfer()
    enum Operation: Equatable { case importing, exporting }
    private(set) var operation: Operation?
    private(set) var progress=TransferProgress(done:0,total:0)
    private(set) var message: String?
    private(set) var lastImportReport: BulkImportReport?
    @ObservationIgnored private var task: Task<Void,Never>?
    @ObservationIgnored private var chooser: NSSavePanel?
    @ObservationIgnored private var pending: [[FileAccessLease]] = []
    @ObservationIgnored private var generation=0
    @ObservationIgnored private var closing=false
    @ObservationIgnored private var paused=false
    var busy: Bool { task != nil || chooser != nil || !pending.isEmpty }
    var progressText: String { UXText.text(operation == .exporting ? "export.zip.progress" : "import.progress",["done":String(progress.done),"total":String(progress.total)]) }
    func dismissMessage() { message=nil }
    func cancel() { pending.removeAll(); generation += 1; chooser?.cancel(nil); chooser=nil; task?.cancel(); if task == nil {operation=nil} }
    func wait() async { await task?.value }
    func beginShutdown() { closing=true; cancel() }
    func pauseForMove() async { paused=true; cancel(); await wait() }
    func resumeAfterMove() { guard !closing else {return};paused=false;startNext() }
    func importFiles(_ urls:[URL]) {
        guard !closing else {return}
        guard LibraryLocationModel.shared.available else {
            NSApp.presentError(NSError(domain:"CassiniLibraryLocation",code:1,userInfo:[NSLocalizedDescriptionKey:LibraryLocationModel.shared.problem ?? POSIXError(.EACCES).localizedDescription]));return
        }
        let leases=urls.filter(\.isFileURL).map(FileAccessLease.init)
        guard !leases.isEmpty else {return}
        pending.append(leases); startNext()
    }
    private func startNext() {
        guard !closing, !paused, task == nil, chooser == nil, !pending.isEmpty else {return}
        let leases=pending.removeFirst(),roots=LibraryLocationModel.shared.roots
        guard let root=roots.first else {return}
        generation += 1; let epoch=generation
        message=nil; operation = .importing; progress = .init(done:0,total:leases.count)
        MeetingNavigation.shared.openLibrary?()
        task=Task {
            let work=Task.detached(priority:.userInitiated) { [leases] in
                defer { withExtendedLifetime(leases) {} }
                return LibraryBulkImport.run(leases.map(\.url),into:root,additionalRoots:Array(roots.dropFirst()),shouldCancel:{Task.isCancelled},progress:{ update in
                    Task { @MainActor in
                        guard self.generation==epoch, self.task != nil else {return}
                        self.progress=update
                    }
                })
            }
            let report=await withTaskCancellationHandler(operation:{await work.value},onCancel:{work.cancel()})
            lastImportReport=report
            if let meeting=report.lastMeeting { LibrarySearchModel.shared.close(); MeetingNavigation.shared.back(); _ = LibraryStore.shared.selectImported(meeting) }
            else { LibraryStore.shared.refresh() }
            if !closing { message=Self.summary(report) }
            task=nil; operation=nil; startNext()
        }
    }
    static func summary(_ report:BulkImportReport) -> String {
        var parts:[String]=[]
        if report.cancelled {parts.append(UXText.text("import.cancelled"))}
        for (id,count) in [("import.summary.imported",report.imported),("import.summary.duplicates",report.duplicates),("import.summary.unsupported",report.unsupported),("import.summary.failed",report.failed)] where count>0 {
            parts.append(UXText.text(id,["n":String(count)]))
        }
        var shown=Set<ZIPFailure>()
        for error in report.archives where shown.insert(error).inserted {
            let id:String
            switch error {
            case .damaged,.entry:id="import.zip.failed.damaged"
            case .encrypted:id="import.zip.failed.encrypted"
            case .unsafePaths:id="import.zip.failed.unsafePaths"
            case .tooLarge:id="import.zip.failed.tooLarge"
            case .empty:id="import.zip.failed.empty"
            }
            parts.append(UXText.text(id))
        }
        return parts.joined(separator:" · ")
    }
    func export(_ meetings:[LibraryMeeting]) {
        guard !closing, !busy, !MeetingExportCoordinator.shared.isBusy, !LibraryMoveCoordinator.shared.busy, !meetings.isEmpty else {return}
        let panel=NSSavePanel();panel.allowedContentTypes=[.zip];panel.nameFieldStringValue="Cassini.zip";panel.canCreateDirectories=true
        generation += 1; let epoch=generation
        chooser=panel; operation = .exporting; message=nil
        panel.begin { response in MainActor.assumeIsolated {
            self.acceptChoice(meetings,epoch:epoch,url:response == .OK ? panel.url : nil)
        } }
    }
    private func acceptChoice(_ meetings:[LibraryMeeting],epoch:Int,url:URL?) {
        guard generation == epoch else {return}
        chooser=nil
        guard !closing,!paused,let url else {operation=nil;startNext();return}
        startExport(meetings,to:FileAccessLease(url))
    }
    #if DEBUG
    func staleExportChoiceForTesting(_ meetings:[LibraryMeeting],to destination:URL) async {
        precondition(RecordingFixture.enabled && !busy)
        let stale=generation
        cancel()
        acceptChoice(meetings,epoch:stale,url:destination)
        await wait()
    }
    func exportForTesting(_ meetings:[LibraryMeeting],to destination:URL) async {
        precondition(RecordingFixture.enabled && !busy)
        operation = .exporting
        startExport(meetings,to:FileAccessLease(destination))
        await wait()
    }
    #endif
    private func startExport(_ meetings:[LibraryMeeting],to destination:FileAccessLease) {
        generation += 1;let epoch=generation
        progress = .init(done:0,total:meetings.count)
        task=Task {
            do {
                let work=Task.detached(priority:.userInitiated) { [destination] in
                    defer {withExtendedLifetime(destination) {}}
                    let assets=meetings.contains(where:{$0.state.origin == .own}) ? try OpusAssets.bundled(app:Bundle.main.bundleURL) : nil
                    let artifact=try MeetingArchiveExporter.make(meetings,assets:assets,shouldCancel:{Task.isCancelled},progress:{ update in
                        Task { @MainActor in guard self.generation==epoch,self.task != nil else {return};self.progress=update }
                    })
                    try Task.checkCancellation()
                    try ExportDestination.selectedFile(artifact,url:destination.url,shouldCancel:{Task.isCancelled})
                }
                try await withTaskCancellationHandler(operation:{try await work.value},onCancel:{work.cancel()})
                if !closing {message=UXText.text("export.zip.done",["n":String(meetings.count)])}
            } catch is CancellationError {} catch {if !closing {NSApp.presentError(error)}}
            task=nil;operation=nil;startNext()
        }
    }
}
