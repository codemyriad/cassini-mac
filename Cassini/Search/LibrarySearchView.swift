// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import CassiniLibrary
import CassiniSearch

struct LibrarySearchView: View {
    @State private var model = LibrarySearchModel.shared
    let format: LibraryFormat
    var body: some View {
        HStack(spacing:0) {
            VStack(alignment:.leading,spacing:10) {
                LibrarySearchField(text:$model.query,large:true,focusRequest:model.focusRequest,onChange:{ model.refresh() },onCancel:{ model.close() })
                    .frame(height:36).padding(.top,6)
                HStack(spacing:7) {
                    Menu {
                        Button(UXText.text("search.filter.anySpeaker")) { model.speaker = nil; model.refresh() }
                        Divider()
                        ForEach(model.names,id:\.self) { name in Button(name) { model.speaker = name; model.refresh() } }
                    } label: {
                        Text(model.speaker.map { UXText.text("search.filter.speaker",["name":$0]) } ?? UXText.text("search.filter.speakerNone"))
                            .foregroundStyle(model.speaker != nil ? .white : Color(nsColor:.labelColor))
                    }.menuIndicator(.hidden).menuStyle(.borderlessButton).buttonStyle(.plain).fixedSize()
                        .modifier(SearchChip(active:model.speaker != nil)).accessibilityIdentifier("search-speaker")
                    Menu {
                        ForEach(SearchDate.allCases,id:\.self) { date in Button(dateText(date)) { model.date = date; model.refresh() } }
                    } label: { Text(dateText(model.date)) }.menuIndicator(.hidden).menuStyle(.borderlessButton).buttonStyle(.plain).fixedSize()
                        .modifier(SearchChip(active:model.date != .any)).accessibilityIdentifier("search-date")
                    Button(UXText.text("search.filter.recordedByMe")) { model.own.toggle(); model.refresh() }.buttonStyle(.plain)
                        .modifier(SearchChip(active:model.own)).accessibilityAddTraits(model.own ? .isSelected : [])
                        .accessibilityIdentifier("search-own")
                }
                Text(model.count).font(.system(size:11.5)).foregroundStyle(LibraryTheme.dim).accessibilityIdentifier("search-count")
                ScrollView {
                    LazyVStack(spacing:4) {
                        ForEach(model.hits) { hit in if let meeting = model.meeting(hit) { row(hit,meeting:meeting) } }
                    }
                }.padding(.horizontal,-5)
            }.padding(.horizontal,14).frame(width:460).background(LibraryTheme.sidebar)
                .accessibilityElement(children:.contain).accessibilityLabel(UXText.text("search.results.a11y"))
            Divider()
            if let hit = model.selected, let meeting = model.meeting(hit) { context(hit,meeting:meeting) }
            else { Color(nsColor:.textBackgroundColor) }
        }.onChange(of:model.query) { _,_ in model.refresh() }
    }
    private func row(_ hit: SearchHit, meeting: LibraryMeeting) -> some View {
        let selected = model.selectedID == hit.id, dim = selected ? Color.white.opacity(0.86) : LibraryTheme.dim
        let excerpt = hit.excerpt
        return Button { model.selectedID = hit.id } label: {
            VStack(alignment:.leading,spacing:5) {
                HStack {
                    Text(meeting.title ?? UXText.text("library.untitled")).fontWeight(.semibold).lineLimit(1)
                    Spacer(minLength:4)
                    if let date = meeting.start { Text(format.searchDate(date)).foregroundStyle(dim).lineLimit(1) }
                }.font(.system(size:11.5))
                (Text("“") + marked(excerpt.text,spans:excerpt.spans,selected:selected) + Text("”"))
                    .lineSpacing(4).fixedSize(horizontal:false,vertical:true)
                Text(UXText.text("search.result.meta",["name":name(hit.speaker,meeting:meeting),"position":LibraryFormat.position(hit.positionMs)]))
                    .font(.system(size:11.5)).foregroundStyle(dim)
            }.padding(.horizontal,12).padding(.vertical,10).frame(maxWidth:.infinity,alignment:.leading)
                .foregroundStyle(selected ? .white : Color(nsColor:.labelColor))
                .background(selected ? Color.accentColor : Color.clear,in:RoundedRectangle(cornerRadius:7))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).disabled(model.searching).accessibilityIdentifier("search-hit-" + hit.id)
            .accessibilityAddTraits(selected ? .isSelected : [])
    }
    private func context(_ hit: SearchHit, meeting: LibraryMeeting) -> some View {
        let turns = MeetingPresentation.turns(meeting.transcriptItems)
        return ScrollView {
            VStack(alignment:.leading,spacing:22) {
                VStack(alignment:.leading,spacing:6) {
                    Text(meeting.title ?? UXText.text("library.untitled")).font(.system(size:22,weight:.bold))
                    if let date = meeting.start {
                        Text(format.searchContext(date,durationMs:meeting.durationMs,positionMs:hit.positionMs)).foregroundStyle(LibraryTheme.dim)
                    }
                }
                VStack(alignment:.leading,spacing:18) {
                    ForEach(Array(turns.enumerated()).filter { abs($0.offset - hit.turn) <= 1 },id:\.offset) { index,turn in
                        HStack(alignment:.top,spacing:16) {
                            VStack(alignment:.leading,spacing:4) {
                                HStack(spacing:5) {
                                    Text(name(turn.speaker,meeting:meeting)).fontWeight(.semibold)
                                    if meeting.speakers.first(where:{ $0.id == turn.speaker })?.provenance == .recognised {
                                        Text(UXText.text("common.autoTag")).font(.system(size:10)).padding(.horizontal,4)
                                            .overlay(RoundedRectangle(cornerRadius:4).stroke(LibraryTheme.dim.opacity(0.3)))
                                            .help(UXText.text("common.autoTag.tooltip"))
                                    }
                                }.fixedSize()
                                if index == hit.turn { Text(LibraryFormat.position(hit.positionMs)).font(.system(size:11.5)).foregroundStyle(LibraryTheme.dim).monospacedDigit() }
                            }.frame(width:110,alignment:.leading)
                            if index == hit.turn { marked(hit.text,spans:hit.spans).lineSpacing(5).frame(maxWidth:.infinity,alignment:.leading) }
                            else { Text(turn.items.map { $0.text.split(whereSeparator:\.isWhitespace).joined(separator:" ") }.joined(separator:" ")).lineSpacing(5).frame(maxWidth:.infinity,alignment:.leading) }
                        }.foregroundStyle(index == hit.turn ? Color(nsColor:.labelColor) : LibraryTheme.dim)
                    }
                }.padding(.top,4)
                ViewThatFits(in:.horizontal) {
                    HStack(spacing:10) { actions(hit,meeting:meeting) }
                    VStack(alignment:.leading,spacing:10) { actions(hit,meeting:meeting) }
                }
            }.padding(.horizontal,44).padding(.vertical,32).frame(maxWidth:.infinity,alignment:.leading)
        }.background(Color(nsColor:.textBackgroundColor)).accessibilityElement(children:.contain)
            .accessibilityLabel(UXText.text("search.context.a11y"))
    }
    @ViewBuilder private func actions(_ hit: SearchHit, meeting: LibraryMeeting) -> some View {
        Button { model.openSelected(play:true) } label: {
            Label(UXText.text("search.context.playFrom",["position":LibraryFormat.position(hit.positionMs)]),systemImage:"play.fill")
                .fontWeight(.semibold).padding(.horizontal,16).frame(height:36)
        }.buttonStyle(.plain).foregroundStyle(.white).background(Color.accentColor,in:RoundedRectangle(cornerRadius:6))
            .disabled(model.searching || (!meeting.canPlaySession && !(meeting.state.origin == .received && !meeting.audioFiles.isEmpty)))
            .accessibilityIdentifier("search-play")
        Button(UXText.text("search.context.openMeeting")) { model.openSelected(play:false) }.buttonStyle(.plain)
            .fontWeight(.semibold).padding(.horizontal,16).frame(height:36).background(LibraryTheme.chip,in:RoundedRectangle(cornerRadius:6))
            .disabled(model.searching).accessibilityIdentifier("search-open-meeting")
    }
    private func name(_ id: String, meeting: LibraryMeeting) -> String { meeting.speakers.first { $0.id == id }?.displayName ?? UXText.text("common.speaker.unnamed",["n":"1"]) }
    private func dateText(_ value: SearchDate) -> String {
        UXText.text(value == .any ? "search.filter.anyDate" : value == .today ? "search.filter.date.today" : value == .week ? "search.filter.date.week" : "search.filter.date.month")
    }
    private func marked(_ text: String, spans: [SearchSpan], selected: Bool = false) -> Text {
        let value = NSMutableAttributedString(string:text)
        for span in spans where span.start >= 0 && span.length > 0 && span.start + span.length <= value.length {
            value.addAttributes([.backgroundColor:selected ? NSColor.white.withAlphaComponent(0.28) : NSColor(red:253/255,green:230/255,blue:138/255,alpha:1),
                                 .font:NSFont.systemFont(ofSize:13,weight:.semibold)],range:NSRange(location:span.start,length:span.length))
        }
        return Text(AttributedString(value))
    }
}
private struct SearchChip: ViewModifier {
    let active: Bool
    func body(content: Content) -> some View {
        content.font(.system(size:11.5,weight:active ? .semibold : .regular)).padding(.horizontal,11).frame(height:28)
            .foregroundStyle(active ? .white : Color(nsColor:.labelColor))
            .background(active ? Color.accentColor : Color(nsColor:.textBackgroundColor),in:Capsule())
            .overlay(Capsule().stroke(active ? Color.clear : Color.secondary.opacity(0.25)))
    }
}

/// Native field, including its accessibility, clear control and text editing.
struct LibrarySearchField: NSViewRepresentable {
    @Binding var text: String
    var large = false
    var focusRequest = 0
    var onBegin: () -> Void = {}
    var onChange: () -> Void
    var onCancel: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> FocusableSearchField {
        let field = FocusableSearchField(); field.delegate = context.coordinator; field.controlSize = large ? .large : .regular
        field.font = NSFont.systemFont(ofSize:13)
        field.placeholderString = UXText.text("search.field.placeholder"); field.setAccessibilityLabel(UXText.text("search.field.a11y"))
        field.setAccessibilityIdentifier("library-search-field")
        if let cell = field.cell as? NSSearchFieldCell { cell.cancelButtonCell?.target = context.coordinator; cell.cancelButtonCell?.action = #selector(Coordinator.cancel) }
        return field
    }
    func updateNSView(_ view: FocusableSearchField, context: Context) {
        context.coordinator.parent = self
        if view.stringValue != text { view.stringValue = text }
        if focusRequest != context.coordinator.focused {
            context.coordinator.focused = focusRequest
            if focusRequest > 0 { view.requestFocus() }
        }
    }
    // SwiftUI may update the field before attaching it to a window. Retain the
    // request until attachment rather than losing Cmd-F's keyboard focus.
    final class FocusableSearchField: NSSearchField {
        private var needsFocus = false
        func requestFocus() { needsFocus = true; applyFocus() }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); applyFocus() }
        private func applyFocus() {
            guard needsFocus, window != nil else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.needsFocus, let window = self.window else { return }
                if window.makeFirstResponder(self) {
                    // The toolbar field is replaced after the first typed
                    // character opens Search. AppKit selects the new field's
                    // entire value by default; the next character would then
                    // replace that first character. Continue at the caret.
                    if let editor = self.currentEditor() {
                        editor.selectedRange = NSRange(location:(self.stringValue as NSString).length,length:0)
                    }
                    self.needsFocus = false
                }
            }
        }
    }
    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: LibrarySearchField; var focused = 0
        init(_ parent: LibrarySearchField) { self.parent = parent }
        func controlTextDidBeginEditing(_ notification: Notification) { parent.onBegin() }
        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            parent.text = field.stringValue; parent.onChange()
        }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) { cancel(); return true }; return false
        }
        @objc func cancel() { parent.text = ""; parent.onCancel() }
    }
}
