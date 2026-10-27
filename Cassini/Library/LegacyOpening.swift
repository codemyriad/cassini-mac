// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import CassiniKit
import CassiniLibrary
import SwiftUI

/// Scene identity contains no transport request, including in restoration data.
struct LegacyRoute: Codable, Hashable {
    let url: URL
    init(url: URL) { self.url = url.standardizedFileURL }
}

@MainActor
enum LegacyOpening {
    static var handler: ((URL) -> Void)? {
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

    static func openDocument(_ requestedURL: URL, autoplay: Bool = false) {
        SessionPlaybackController.stopAll()
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
        panel.allowedContentTypes = CassiniDocument.readableContentTypes
        panel.canChooseDirectories = false; panel.allowsMultipleSelection = true
        openPanel = panel
        panel.begin { response in
            MainActor.assumeIsolated {
                openPanel = nil
                if response == .OK { panel.urls.forEach { openDocument($0) } }
            }
        }
    }
    private static var transcriptWindows: [String: TranscriptWindowController] = [:]
    static func openTranscript(_ meeting: LibraryMeeting) {
        // UX3 owns the full new Meeting page. This interim read-only window uses
        // the already-read Library items and shared speaker labels, without a file import.
        if let controller = transcriptWindows[meeting.libraryKey] {
            controller.update(meeting); controller.showWindow(nil); return
        }
        let controller = TranscriptWindowController(meeting: meeting)
        let key = meeting.libraryKey
        controller.onClose = { closing in
            if transcriptWindows[key] === closing { transcriptWindows.removeValue(forKey: key) }
        }
        transcriptWindows[key] = controller
        controller.showWindow(nil)
    }
    static func refreshTranscripts(_ meetings: [LibraryMeeting]) {
        for meeting in meetings { transcriptWindows[meeting.libraryKey]?.update(meeting) }
    }
}
struct LegacyDocumentView: View {
    @State private var model: LegacyDocumentModel
    @Environment(\.dismissWindow) private var dismissWindow
    init(url: URL) { _model = State(initialValue: LegacyDocumentModel(url: url)) }
    var body: some View {
        Group {
            if let session = model.session {
                DocumentView(session: session)
                    .background(WindowAccessor { window in
                        guard let window else { return }
                        #if DEBUG
                        if ["window", "sheet"].contains(LibraryLaunchContext.argument("-CassiniScreenshot") ?? "") {
                            ScreenshotFixture.prepareLegacy(window); return
                        }
                        #endif
                        window.setAccessibilityIdentifier("cassini-legacy-window")
                    })
            } else { ProgressView() }
        }
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

private struct TranscriptDetailView: View {
    let meeting: LibraryMeeting
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                Text(meeting.title ?? UXText.text("library.untitled")).font(.title.bold())
                ForEach(Array(meeting.transcriptTurns.enumerated()), id: \.offset) { _, turn in
                    HStack(alignment: .top, spacing: 16) {
                        Text(meeting.speakers.first { $0.id == turn.speaker }?.displayName ?? "").fontWeight(.semibold).frame(width: 110, alignment: .leading)
                        Text(LibraryFormat.position(turn.startMs)).monospacedDigit().foregroundStyle(.secondary)
                        Text(turn.text).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }.padding(32)
        }
    }
}
@MainActor private final class TranscriptWindowController: NSWindowController, NSWindowDelegate {
    var onClose: ((TranscriptWindowController) -> Void)?
    private let host: NSHostingController<TranscriptDetailView>
    private var meeting: LibraryMeeting
    init(meeting: LibraryMeeting) {
        self.meeting = meeting
        host = NSHostingController(rootView: TranscriptDetailView(meeting: meeting))
        let window = NSWindow(contentViewController: host)
        // AppKit must retain its window/controller invariants until _close has
        // unwound; the registry is released only on the next main-queue turn.
        window.isReleasedWhenClosed = false
        window.title = meeting.title ?? UXText.text("library.untitled")
        window.setAccessibilityIdentifier("cassini-transcript-window")
        window.setContentSize(NSSize(width: 1000, height: 660)); window.styleMask.insert([.resizable, .miniaturizable])
        super.init(window: window)
        window.delegate = self
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }
    func update(_ next: LibraryMeeting) {
        guard meeting.title != next.title || meeting.speakers != next.speakers || meeting.transcriptItems != next.transcriptItems else { return }
        meeting = next; host.rootView = TranscriptDetailView(meeting: next)
        window?.title = next.title ?? UXText.text("library.untitled")
    }
    func windowWillClose(_ notification: Notification) {
        DispatchQueue.main.async { [self] in
            // A rapid reopen keeps the same live controller registered.
            guard window?.isVisible != true else { return }
            window?.delegate = nil
            onClose?(self)
        }
    }
}
