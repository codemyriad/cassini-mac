import AppKit
import CassiniKit
import CassiniLibrary
import SwiftUI

struct LegacyRoute: Codable, Hashable { let url: URL; var autoplay = false }

@MainActor
enum LegacyOpening {
    static var handler: ((URL) -> Void)?
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
    let url: URL
    var autoplay = false
    @State private var document: CassiniDocument?
    @State private var scoped = false
    var body: some View {
        Group {
            if let document {
                DocumentView(document: document, fileURL: url, autoPlay: autoplay)
                    .background(WindowAccessor { window in
                        #if DEBUG
                        if let window { ScreenshotFixture.prepareLegacy(window) }
                        #endif
                    })
            } else { ProgressView() }
        }
        .task(id: url) {
            scoped = url.startAccessingSecurityScopedResource()
            do { document = try await Task.detached { try CassiniDocument(url: url) }.value }
            catch { NSApp.presentError(error) }
        }
        .onDisappear { if scoped { url.stopAccessingSecurityScopedResource(); scoped = false } }
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
