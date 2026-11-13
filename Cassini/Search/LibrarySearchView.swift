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
                            .foregroundStyle(model.speaker != nil ? CassiniTheme.onAccent : CassiniTheme.ink)
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
                Text(model.count).font(.system(size:11.5)).foregroundStyle(CassiniTheme.ink2).accessibilityIdentifier("search-count")
                ScrollView {
                    LazyVStack(spacing:4) {
                        ForEach(model.hits) { hit in if let meeting = model.meeting(hit) { row(hit,meeting:meeting) } }
                    }
                }.padding(.horizontal,-5)
            }.padding(.horizontal,14).frame(width:460).background(NativeSidebarMaterial())
                .accessibilityElement(children:.contain).accessibilityLabel(UXText.text("search.results.a11y"))
            Divider()
            if let hit = model.selected, let meeting = model.meeting(hit) { context(hit,meeting:meeting) }
            else { CassiniTheme.paneGround }
        }.onChange(of:model.query) { _,_ in model.refresh() }
    }
    private func row(_ hit: SearchHit, meeting: LibraryMeeting) -> some View {
        let selected = model.selectedID == hit.id, dim = selected ? CassiniTheme.onAccentDim : CassiniTheme.ink2
        let excerpt = hit.excerpt
        return Button { model.selectedID = hit.id } label: {
            VStack(alignment:.leading,spacing:5) {
                HStack {
                    Text(meeting.title ?? UXText.text("library.untitled")).fontWeight(.semibold).lineLimit(1)
                    Spacer(minLength:4)
                    Text(format.searchDate(meeting.meetingTime)).foregroundStyle(dim).lineLimit(1)
                }.font(.system(size:11.5))
                (Text("“") + marked(excerpt.text,spans:excerpt.spans,selected:selected) + Text("”"))
                    .lineSpacing(4).fixedSize(horizontal:false,vertical:true)
                Text(UXText.text("search.result.meta",["name":name(hit.speaker,meeting:meeting),"position":LibraryFormat.position(hit.positionMs)]))
                    .font(.system(size:11.5)).foregroundStyle(dim)
            }.padding(.horizontal,12).padding(.vertical,10).frame(maxWidth:.infinity,alignment:.leading)
                .foregroundStyle(selected ? CassiniTheme.onAccent : CassiniTheme.ink)
                .background(selected ? CassiniTheme.accentStrong : Color.clear,in:RoundedRectangle(cornerRadius:7))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).disabled(model.searching).accessibilityIdentifier("search-hit-" + hit.id)
            .accessibilityAddTraits(selected ? .isSelected : [])
    }
    private func context(_ hit: SearchHit, meeting: LibraryMeeting) -> some View {
        // The index prepared these turns off the main actor (#118 review).
        return ScrollView {
            VStack(alignment:.leading,spacing:22) {
                VStack(alignment:.leading,spacing:6) {
                    Text(meeting.title ?? UXText.text("library.untitled")).font(.system(size:22,weight:.bold))
                    Text(format.searchContext(meeting.meetingTime,durationMs:meeting.durationMs,positionMs:hit.positionMs)).foregroundStyle(CassiniTheme.ink2)
                }
                VStack(alignment:.leading,spacing:18) {
                    ForEach(hit.context,id:\.index) { index,turn in
                        let others = meeting.overlappingSpeakerIDs(turn.over,excluding:turn.speaker)
                        HStack(alignment:.top,spacing:16) {
                            VStack(alignment:.leading,spacing:4) {
                                if hit.showsSpeakerHeader(at:index) {
                                    let turnSpeaker = meeting.speaker(for:turn.speaker)
                                    HStack(spacing:5) {
                                        Text(name(turn.speaker,meeting:meeting)).fontWeight(.semibold)
                                            .foregroundStyle(index == hit.turn ? CassiniTheme.speakerInk(turnSpeaker) : CassiniTheme.ink2)
                                        if turnSpeaker?.provenance == .recognised {
                                            Text(UXText.text("common.autoTag")).font(.system(size:10)).padding(.horizontal,4)
                                                .overlay(RoundedRectangle(cornerRadius:4).stroke(CassiniTheme.tagStroke))
                                                .help(UXText.text("common.autoTag.tooltip"))
                                        }
                                    }.fixedSize()
                                }
                                if index == hit.turn { Text(LibraryFormat.position(hit.positionMs)).font(.system(size:11.5)).foregroundStyle(CassiniTheme.ink2).monospacedDigit() }
                                if !others.isEmpty { Text(UXText.text("meeting.turn.over",["names":LibraryFormat(locale:UXText.locale,language:UXText.language).list(others.map { name($0,meeting:meeting) })])).font(.system(size:11.5)).foregroundStyle(CassiniTheme.ink2) }
                            }.frame(width:110,alignment:.leading)
                            if index == hit.turn { marked(hit.text,spans:hit.spans).lineSpacing(5).frame(maxWidth:.infinity,alignment:.leading) }
                            else { Text(hit.contextText[index] ?? "").lineSpacing(5).frame(maxWidth:.infinity,alignment:.leading) }
                        }.foregroundStyle(index == hit.turn ? CassiniTheme.ink : CassiniTheme.ink2)
                    }
                }.padding(.top,4)
                ViewThatFits(in:.horizontal) {
                    HStack(spacing:10) { actions(hit,meeting:meeting) }
                    VStack(alignment:.leading,spacing:10) { actions(hit,meeting:meeting) }
                }
            }.padding(.horizontal,44).padding(.vertical,32).frame(maxWidth:.infinity,alignment:.leading)
        }.background(CassiniTheme.paneGround).accessibilityElement(children:.contain)
            .accessibilityLabel(UXText.text("search.context.a11y"))
    }
    @ViewBuilder private func actions(_ hit: SearchHit, meeting: LibraryMeeting) -> some View {
        Button { model.openSelected(play:true) } label: {
            Label(UXText.text("search.context.playFrom",["position":LibraryFormat.position(hit.positionMs)]),systemImage:"play.fill")
                .fontWeight(.semibold).padding(.horizontal,16).frame(height:36)
        }.buttonStyle(.plain).foregroundStyle(CassiniTheme.onAccent).background(CassiniTheme.accentStrong,in:RoundedRectangle(cornerRadius:6))
            .disabled(model.searching || (!meeting.canPlaySession && !(meeting.state.origin == .received && !meeting.audioFiles.isEmpty)))
            .accessibilityIdentifier("search-play")
        Button(UXText.text("search.context.openMeeting")) { model.openSelected(play:false) }.buttonStyle(.plain)
            .fontWeight(.semibold).padding(.horizontal,16).frame(height:36).background(CassiniTheme.chipFill,in:RoundedRectangle(cornerRadius:6))
            .disabled(model.searching).accessibilityIdentifier("search-open-meeting")
    }
    private func name(_ id: String, meeting: LibraryMeeting) -> String { meeting.speaker(for:id)?.displayName ?? UXText.text("common.speaker.unnamed",["n":"1"]) }
    private func dateText(_ value: SearchDate) -> String {
        UXText.text(value == .any ? "search.filter.anyDate" : value == .today ? "search.filter.date.today" : value == .week ? "search.filter.date.week" : "search.filter.date.month")
    }
    private func marked(_ text: String, spans: [SearchSpan], selected: Bool = false) -> Text {
        let value = NSMutableAttributedString(string:text)
        for span in spans where span.start >= 0 && span.length > 0 && span.start + span.length <= value.length {
            var attrs: [NSAttributedString.Key: Any] = [
                .backgroundColor: selected ? CassiniTheme.nsSelectedSearchHighlight : CassiniTheme.nsSearchHighlight,
                .font: NSFont.systemFont(ofSize:13,weight:.semibold),
            ]
            if !selected, let highlightInk = CassiniTheme.nsHighlightInk {
                attrs[.foregroundColor] = highlightInk
            }
            value.addAttributes(attrs,range:NSRange(location:span.start,length:span.length))
        }
        return Text(AttributedString(value))
    }
}
private struct SearchChip: ViewModifier {
    let active: Bool
    func body(content: Content) -> some View {
        content.font(.system(size:12,weight:.medium)).padding(.horizontal,12).frame(height:28)
            .foregroundStyle(active ? CassiniTheme.onAccent : CassiniTheme.ink)
            .background(active ? CassiniTheme.accentStrong : CassiniTheme.chipFill,in:Capsule())
    }
}

/// Native field, including its accessibility, clear control and text editing.
/// Draws `field` fill and `field-line` border (HARMONY 10.8, 10.14) with full-opacity `ink-3` placeholder.
struct LibrarySearchField: NSViewRepresentable {
    @Binding var text: String
    var large = false
    var focusRequest = 0
    var onClick: (() -> Void)?
    var onBegin: () -> Void = {}
    var onChange: () -> Void
    var onCancel: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> FocusableSearchField {
        let field = FocusableSearchField(); field.delegate = context.coordinator; field.controlSize = large ? .large : .regular
        field.isBezeled = true; field.bezelStyle = .roundedBezel; field.drawsBackground = false
        field.isEditable = true; field.isSelectable = true
        field.focusRingType = .default
        field.font = NSFont.systemFont(ofSize:13)
        field.textColor = CassiniTheme.nsInk
        field.onClick = onClick
        field.placeholderAttributedString = NSAttributedString(
            string: UXText.text("search.field.placeholder"),
            attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: CassiniTheme.nsInk3]
        )
        field.setAccessibilityLabel(UXText.text("search.field.a11y"))
        field.setAccessibilityIdentifier("library-search-field")
        if let cell = field.cell as? NSSearchFieldCell { cell.cancelButtonCell?.target = context.coordinator; cell.cancelButtonCell?.action = #selector(Coordinator.cancel) }
        return field
    }
    func updateNSView(_ view: FocusableSearchField, context: Context) {
        context.coordinator.parent = self
        view.onClick = onClick
        if view.stringValue != text { view.stringValue = text; view.needsDisplay = true }
        if focusRequest != context.coordinator.focused {
            context.coordinator.focused = focusRequest
            if focusRequest > 0 { view.requestFocus() }
        }
    }
    final class BrandedSearchFieldCell: NSSearchFieldCell {
        override func searchButtonRect(forBounds rect: NSRect) -> NSRect {
            let base = super.searchButtonRect(forBounds: rect)
            return NSRect(x: 6, y: base.minY, width: base.width, height: base.height)
        }
        override func cancelButtonRect(forBounds rect: NSRect) -> NSRect {
            guard !stringValue.isEmpty else { return .zero }
            let base = super.cancelButtonRect(forBounds: rect)
            return NSRect(x: rect.maxX - base.width - 6, y: base.minY, width: base.width, height: base.height)
        }
        override func searchTextRect(forBounds rect: NSRect) -> NSRect {
            let minX = searchButtonRect(forBounds: rect).maxX + 4
            let cancel = cancelButtonRect(forBounds: rect)
            let maxX = cancel.width > 0 ? cancel.minX - 4 : rect.maxX - 8
            let h: CGFloat = 16
            return NSRect(x: minX, y: floor((rect.height - h) / 2), width: max(0, maxX - minX), height: h)
        }
        override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {
            let radius: CGFloat = controlSize == .large ? 7 : 6
            let path = NSBezierPath(roundedRect: cellFrame.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius)
            CassiniTheme.nsField.setFill()
            path.fill()
            CassiniTheme.nsFieldLine.setStroke()
            path.lineWidth = 1
            path.stroke()
            drawInterior(withFrame: cellFrame, in: controlView)
        }
    }
    // SwiftUI may update the field before attaching it to a window. Retain the
    // request until attachment rather than losing Cmd-F's keyboard focus.
    final class FocusableSearchField: NSSearchField {
        override class var cellClass: AnyClass? {
            get { BrandedSearchFieldCell.self }
            set {}
        }
        var onClick: (() -> Void)?
        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            needsDisplay = true
        }
        override func mouseDown(with event: NSEvent) {
            // Open the sidebar before AppKit installs a field editor for the toolbar.
            // Replacing an active field editor can drop keys from a single typing burst.
            if let onClick { onClick() }
            else { super.mouseDown(with:event) }
        }
        private var needsFocus = false
        func requestFocus() { needsFocus = true; applyFocus() }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); applyFocus() }
        private func applyFocus() {
            guard needsFocus, window != nil else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.needsFocus, let window = self.window else { return }
                if window.makeFirstResponder(self) {
                    // A keyboard edit can bring a query from the toolbar. Keep
                    // its caret at the end when the sidebar gets the field editor.
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
