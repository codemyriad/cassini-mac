// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import AppKit

struct MeetingRenameView: View {
    @State private var rename = MeetingRenameCoordinator.shared
    var body: some View {
        VStack(alignment:.leading,spacing:18) {
            Text(UXText.text("meeting.rename.title")).font(.system(size:18,weight:.bold)).accessibilityAddTraits(.isHeader)
            HStack(spacing:12) {
                Text(UXText.text("meeting.rename.field"))
                RenameNameField(text:$rename.name,enabled:!rename.working,cancel:{ rename.cancel() },confirm:{ if rename.canApply { rename.apply() } })
                    .frame(maxWidth:.infinity).frame(height:24)
            }
            HStack(spacing:10) {
                Spacer()
                if rename.working { ProgressView().controlSize(.small) }
                Button(UXText.text("common.cancel")) { rename.cancel() }.keyboardShortcut(.cancelAction).disabled(rename.working)
                Button(UXText.text("meeting.rename.confirm")) { rename.apply() }.keyboardShortcut(.defaultAction)
                    .disabled(!rename.canApply).accessibilityIdentifier("rename-confirm")
            }
        }.font(.system(size:13)).padding(24).frame(width:430)
            .accessibilityElement(children:.contain).accessibilityIdentifier("rename-meeting")
            .onExitCommand { if !rename.working { rename.cancel() } }
    }
}
private struct RenameNameField: NSViewRepresentable {
    @Binding var text: String
    let enabled: Bool
    let cancel: () -> Void
    let confirm: () -> Void
    final class Field: NSTextField {
        private var selectedInitially = false
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil, !selectedInitially else { return }; selectedInitially = true
            DispatchQueue.main.async { [weak self] in
                guard let self, let window = self.window else { return }
                window.makeFirstResponder(self); self.selectText(nil)
            }
        }
    }
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: RenameNameField
        init(_ parent: RenameNameField) { self.parent = parent }
        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }; parent.text = field.stringValue
        }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if selector == #selector(NSResponder.cancelOperation(_:)) { parent.cancel(); return true }
            if selector == #selector(NSResponder.insertNewline(_:)) { parent.confirm(); return true }
            return false
        }
        @objc func commit(_ sender: Any?) { parent.confirm() }
    }
    func makeCoordinator() -> Coordinator { .init(self) }
    func makeNSView(context: Context) -> Field {
        let field = Field(); field.stringValue = text; field.isEditable = true; field.isSelectable = true
        field.isBezeled = true; field.bezelStyle = .roundedBezel; field.drawsBackground = true
        field.font = .systemFont(ofSize:13); field.usesSingleLineMode = true
        field.delegate = context.coordinator; field.target = context.coordinator; field.action = #selector(Coordinator.commit(_:))
        field.setAccessibilityIdentifier("rename-name"); field.setAccessibilityLabel(UXText.text("meeting.rename.field"))
        return field
    }
    func updateNSView(_ field: Field, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
        field.isEnabled = enabled
    }
}
