import AppKit
import CassiniKit
import SwiftUI

/// The Export… save panel, with a format picker as its accessory.
@MainActor
enum TranscriptExportPanel {
    static func run(for session: SessionModel) {
        guard let timeline = session.timeline else { return }
        let panel = NSSavePanel()
        let model = FormatChoice()
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "\(session.title).\(model.format.fileExtension)"
        panel.accessoryView = NSHostingView(rootView: FormatAccessory(choice: model) { format in
            let base = (panel.nameFieldStringValue as NSString).deletingPathExtension
            panel.nameFieldStringValue = "\(base).\(format.fileExtension)"
        })
        panel.title = "Export Transcript"
        panel.prompt = "Export"
        let handler: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            let text = TranscriptExporter.export(model.format, title: session.title, timeline: timeline, speakers: session.speakers)
            do {
                try text.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                NSAlert(error: error).runModal()
            }
        }
        if let window = session.window {
            panel.beginSheetModal(for: window, completionHandler: handler)
        } else {
            handler(panel.runModal())
        }
    }
}

@MainActor
@Observable
final class FormatChoice {
    var format: ExportFormat = .markdown
}

private struct FormatAccessory: View {
    @Bindable var choice: FormatChoice
    var onChange: (ExportFormat) -> Void

    var body: some View {
        HStack {
            Picker("Format:", selection: $choice.format) {
                ForEach(ExportFormat.allCases) { f in Text(f.title).tag(f) }
            }
            .frame(width: 280)
            .onChange(of: choice.format) { _, f in onChange(f) }
        }
        .padding(12)
    }
}
