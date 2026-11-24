// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import CassiniKit
import CassiniLibrary
import SwiftUI
import UniformTypeIdentifiers

/// Scene identity contains no transport request, including in restoration data.
struct LegacyRoute: Codable, Hashable {
    let url: URL
    init(url: URL) { self.url = url.standardizedFileURL }
}

@MainActor
enum LegacyOpening {
    static var handler: ((URL) -> Void)? = { ApplicationWindows.legacy($0) } {
        didSet {
            guard let handler else { return }
            let queued = pendingURLs; pendingURLs.removeAll()
            queued.forEach(handler)
        }
    }
    private struct WeakDocument { weak var model: LegacyDocumentModel? }
    private static var documents: [URL: WeakDocument] = [:]
    private static var pendingURLs: [URL] = []
    private static var pendingPlay = Set<URL>()
    private static var pendingAccess: [URL: FileAccessLease] = [:]
    private static var openPanel: NSOpenPanel?

    static func openDocuments(_ requestedURLs: [URL]) {
        let urls = requestedURLs.filter(\.isFileURL)
        guard !urls.isEmpty else { return }
        SessionPlaybackController.stopAll()
        #if DEBUG
        let legacyFixture = ProcessInfo.processInfo.environment["CASSINI_HOSTED_SCREENSHOTS"] == "1" && ["window", "sheet"].contains(LibraryLaunchContext.argument("-CassiniScreenshot") ?? "")
        #else
        let legacyFixture = false
        #endif
        if legacyFixture {
            urls.forEach { openDocument($0) }
            return
        }
        if urls.count == 1 {
            let dottedExt = ImportTypesContract.dottedExtension(for: urls[0].lastPathComponent)
            let ext = dottedExt.hasPrefix(".") ? String(dottedExt.dropFirst()) : ""
            if ext != "zip" && LibraryImport.supportedAudioExtensions.contains(ext) {
                LibraryImportCoordinator.shared.open(urls[0])
                return
            }
        }
        LibraryImportCoordinator.shared.openBatch(urls)
    }

    static func openDocument(_ requestedURL: URL, autoplay: Bool = false) {
        SessionPlaybackController.stopAll()
        #if DEBUG
        let legacyFixture = ProcessInfo.processInfo.environment["CASSINI_HOSTED_SCREENSHOTS"] == "1" && ["window", "sheet"].contains(LibraryLaunchContext.argument("-CassiniScreenshot") ?? "")
        #else
        let legacyFixture = false
        #endif
        if !legacyFixture {
            if requestedURL.pathExtension.lowercased() == "zip" {
                LibraryImportCoordinator.shared.openBatch([requestedURL])
            } else {
                LibraryImportCoordinator.shared.open(requestedURL)
            }
            return
        }
        let url = requestedURL.standardizedFileURL
        if let model = documents[url]?.model {
            if autoplay { model.requestPlay() }
            model.session?.window?.makeKeyAndOrderFront(nil)
        } else {
            // Acquire the original user-selected URL before scene encoding or
            // normalization can discard its security-scope attachment.
            if pendingAccess[url] == nil { pendingAccess[url] = FileAccessLease(requestedURL) }
            if autoplay { pendingPlay.insert(url) }
        }
        if let handler { handler(url) }
        else if !pendingURLs.contains(url) { pendingURLs.append(url) }
    }
    static func register(_ model: LegacyDocumentModel) -> (lease: FileAccessLease, play: Bool) {
        documents[model.url] = WeakDocument(model: model)
        return (pendingAccess.removeValue(forKey: model.url) ?? FileAccessLease(model.url), pendingPlay.remove(model.url) != nil)
    }
    static func unregister(_ model: LegacyDocumentModel) {
        if documents[model.url]?.model === model { documents.removeValue(forKey: model.url) }
        pendingPlay.remove(model.url)
        pendingAccess.removeValue(forKey: model.url)
    }
    static func chooseDocuments() {
        if let openPanel { openPanel.makeKeyAndOrderFront(nil); return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = UTType.decidedImportAudioContentTypes + [.zip]
        panel.message = UXText.mac("import.drop.formats")
        panel.canChooseDirectories = false; panel.allowsMultipleSelection = true
        openPanel = panel
        panel.begin { response in
            MainActor.assumeIsolated {
                openPanel = nil
                if response == .OK { openDocuments(panel.urls) }
            }
        }
    }
}
struct LegacyDocumentView: View {
    @State private var model: LegacyDocumentModel
    @Environment(\.dismissWindow) private var dismissWindow
    init(url: URL) { _model = State(initialValue: LegacyDocumentModel(url: url)) }
    var body: some View {
        Group {
            if let session = model.session {
                let ready = !session.preparingTranscript
                DocumentView(session: session)
                    .background(WindowAccessor { window in
                        guard let window else { return }
                        #if DEBUG
                        if ["window", "sheet"].contains(LibraryLaunchContext.argument("-CassiniScreenshot") ?? "") {
                            guard ready else { window.setAccessibilityIdentifier("cassini-legacy-loading"); return }
                            ScreenshotFixture.prepareLegacy(window); return
                        }
                        #endif
                        window.setAccessibilityIdentifier("cassini-legacy-window")
                    })
            } else { ProgressView() }
        }
        .overlay(alignment: .bottom) { TransferStatusBanner() }
        .onAppear {
            let dismiss = dismissWindow, route = LegacyRoute(url: model.url)
            model.onFailure = { error in
                dismiss(id: "legacy-viewer", value: route)
                DispatchQueue.main.async { NSApp.presentError(error) }
            }
            model.start()
        }
        .onDisappear { model.close() }
    }
}
