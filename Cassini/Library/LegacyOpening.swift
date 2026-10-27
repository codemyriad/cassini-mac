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
        if let controller = transcriptWindows[meeting.libraryKey] { controller.showWindow(nil); return }
        let view = ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(meeting.title ?? UXText.text("library.untitled")).font(.title.bold())
                ForEach(Array(meeting.transcriptItems.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .top, spacing: 16) {
                        Text(meeting.speakers.first { $0.id == item.speaker }?.displayName ?? "").fontWeight(.semibold).frame(width: 110, alignment: .leading)
                        Text(LibraryFormat.position(item.startMs)).monospacedDigit().foregroundStyle(.secondary)
                        Text(item.text).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }.padding(32)
        }
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.title = meeting.title ?? UXText.text("library.untitled")
        window.setContentSize(NSSize(width: 1000, height: 660)); window.styleMask.insert([.resizable, .miniaturizable])
        let controller = TranscriptWindowController(window: window)
        controller.onClose = { transcriptWindows.removeValue(forKey: meeting.libraryKey) }
        window.delegate = controller; transcriptWindows[meeting.libraryKey] = controller
        controller.showWindow(nil)
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

@MainActor private final class TranscriptWindowController: NSWindowController, NSWindowDelegate {
    var onClose: (() -> Void)?
    func windowWillClose(_ notification: Notification) { onClose?() }
}
