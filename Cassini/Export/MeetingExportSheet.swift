// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import CassiniLibrary

struct MeetingExportSheet: View {
    @State private var coordinator = MeetingExportCoordinator.shared
    let meeting: LibraryMeeting
    var body: some View {
        VStack(alignment:.leading,spacing:20) {
            VStack(alignment:.leading,spacing:6) {
                Text(UXText.text("export.title",["title":meeting.title ?? UXText.text("library.untitled")])).font(.system(size:20,weight:.bold))
                Text(UXText.text("export.subtitle")).foregroundStyle(LibraryTheme.dim)
            }
            VStack(spacing:0) {
                option(.cassini,title:"export.cassiniFile.label",description:"export.cassiniFile.description")
                Divider()
                option(.markdown,title:"export.markdown.label",description:"export.markdown.description")
            }.background(Color(nsColor:.textBackgroundColor),in:RoundedRectangle(cornerRadius:8))
                .clipShape(RoundedRectangle(cornerRadius:8)).overlay { RoundedRectangle(cornerRadius:8).stroke(Color.secondary.opacity(0.25)) }
                .accessibilityElement(children:.contain).accessibilityLabel(UXText.text("export.formatGroup.a11y"))
            VStack(alignment:.leading,spacing:6) {
                Text(UXText.text("export.speakerNames.heading")).font(.system(size:11.5,weight:.bold)).foregroundStyle(LibraryTheme.dim)
                ScrollView { speakerNames.lineSpacing(5).fixedSize(horizontal:false,vertical:true).frame(maxWidth:.infinity,alignment:.leading) }
                    .frame(maxHeight:130).fixedSize(horizontal:false,vertical:true)
            }
            HStack(spacing:12) {
                Image(systemName:"folder").accessibilityHidden(true)
                template("export.saveTo",token:"folder",value:Text(coordinator.directory.lastPathComponent).fontWeight(.semibold))
                Spacer()
                Button(UXText.text("common.choose")) { coordinator.chooseDirectory() }.buttonStyle(.plain)
                    .fontWeight(.semibold).padding(.horizontal,14).frame(height:30).background(LibraryTheme.chip,in:RoundedRectangle(cornerRadius:6))
                    .accessibilityIdentifier("export-choose-folder")
            }.padding(14).background(LibraryTheme.chip.opacity(0.65),in:RoundedRectangle(cornerRadius:7))
            HStack(spacing:10) {
                Spacer()
                if coordinator.working { ProgressView().controlSize(.small) }
                Button(UXText.text("common.cancel")) { coordinator.cancel() }.keyboardShortcut(.cancelAction)
                    .buttonStyle(.plain).fontWeight(.semibold).padding(.horizontal,18).frame(height:36).background(LibraryTheme.chip,in:RoundedRectangle(cornerRadius:6))
                Button(UXText.text("export.exportButton")) { coordinator.perform() }.keyboardShortcut(.defaultAction)
                    .buttonStyle(.plain).fontWeight(.semibold).padding(.horizontal,18).frame(height:36)
                    .foregroundStyle(.white).background(Color.accentColor,in:RoundedRectangle(cornerRadius:6))
                    .disabled(coordinator.working).accessibilityIdentifier("export-confirm")
            }
        }.font(.system(size:13)).padding(26).frame(width:540)
            .accessibilityElement(children:.contain).accessibilityIdentifier("meeting-export-sheet")
    }
    private func option(_ kind: MeetingExportKind, title: String, description: String) -> some View {
        HStack(spacing:14) {
            ExportRadio(selected:coordinator.kind == kind,label:UXText.text(title)) { coordinator.kind = kind }.frame(width:20,height:20)
            VStack(alignment:.leading,spacing:3) {
                Text(UXText.text(title)).fontWeight(.semibold)
                Text(UXText.text(description)).font(.system(size:11.5)).foregroundStyle(LibraryTheme.dim)
            }.frame(maxWidth:.infinity,alignment:.leading)
            if kind == .cassini, let bytes = coordinator.estimatedBytes {
                Text(LibraryFormat.size(bytes:bytes,approximate:true)).font(.system(size:11.5)).foregroundStyle(LibraryTheme.dim)
            }
        }.padding(.horizontal,16).frame(minHeight:55)
            .background(coordinator.kind == kind ? Color.accentColor.opacity(0.10) : Color.clear)
            .contentShape(Rectangle()).onTapGesture { if kind != .cassini || !meeting.audioFiles.isEmpty { coordinator.kind = kind } }
            .disabled(coordinator.working || (kind == .cassini && meeting.audioFiles.isEmpty))
            .accessibilityElement(children:.contain).accessibilityIdentifier(kind == .cassini ? "export-cassini" : "export-markdown")
    }
    private var speakerNames: Text {
        let names = meeting.speakers.filter { $0.provenance == .recognised }.map(\.displayName)
        if names.isEmpty { return Text(UXText.text("export.speakerNames.body.none")) }
        if names.count == 1 { return template("export.speakerNames.body",token:"name",value:Text(names[0]).fontWeight(.semibold)) }
        let formatter = ListFormatter(); formatter.locale = Locale(identifier:"en_GB")
        let tokens = names.indices.map { "\u{F0000}\($0)\u{F0001}" }
        var remaining = formatter.string(from:tokens) ?? tokens.joined(separator:", "), result = Text("")
        for (index,token) in tokens.enumerated() {
            if let range = remaining.range(of:token) {
                result = result + Text(String(remaining[..<range.lowerBound])) + Text(names[index]).fontWeight(.semibold)
                remaining = String(remaining[range.upperBound...])
            }
        }
        return template("export.speakerNames.body.several",token:"names",value:result + Text(remaining))
    }
    private func template(_ id: String, token: String, value: Text) -> Text {
        let text = UXText.text(id)
        guard let range = text.range(of:"{\(token)}") else { return Text(text) }
        return Text(String(text[..<range.lowerBound])) + value + Text(String(text[range.upperBound...]))
    }
}
private struct ExportRadio: NSViewRepresentable {
    let selected: Bool
    let label: String
    let action: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(action) }
    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(title:"",target:context.coordinator,action:#selector(Coordinator.select))
        button.setButtonType(.radio); button.setAccessibilityLabel(label); return button
    }
    func updateNSView(_ view: NSButton, context: Context) { view.state = selected ? .on : .off; context.coordinator.action = action }
    final class Coordinator: NSObject {
        var action: () -> Void
        init(_ action: @escaping () -> Void) { self.action = action }
        @objc func select() { action() }
    }
}
