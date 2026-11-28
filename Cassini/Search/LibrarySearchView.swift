// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import CassiniLibrary
import CassiniSearch

struct LibrarySearchView: View {
    @State private var model = LibrarySearchModel.shared
    let format: LibraryFormat
    var body: some View {
        HStack(spacing:0) {
            LibrarySearchSidebarContent(format: format, showEmbeddedField: true)
                .frame(width:390).cassiniSidebarBackground()
                .accessibilityElement(children:.contain).accessibilityLabel(UXText.text("search.results.a11y"))
            CassiniColumnDivider()
            if let hit = model.selected, let meeting = model.meeting(hit) {
                LibrarySearchPreviewPane(hit: hit, meeting: meeting, format: format)
            } else {
                CassiniTheme.paneGround
            }
        }.onChange(of:model.query) { _,_ in model.refresh() }
    }
}

/// In-sidebar search results list (D-1172): swaps in place of the meeting list while keeping
/// the sidebar width, toolbar, and open meeting still until a result is picked.
struct LibrarySearchSidebarContent: View {
    @State private var model = LibrarySearchModel.shared
    let format: LibraryFormat
    var showEmbeddedField: Bool = false
    var onPickResult: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            searchHeader
            ScrollView {
                LazyVStack(spacing: MeetingCard<EmptyView>.Metrics.interCardGap) {
                    ForEach(model.hits) { hit in
                        if let meeting = model.meeting(hit) {
                            row(hit, meeting: meeting)
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
            }
            .cassiniTopScrollEdge()
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(UXText.text("search.results.a11y"))
        .onKeyPress(.downArrow) {
            stepSelection(1)
            return .handled
        }
        .onKeyPress(.upArrow) {
            stepSelection(-1)
            return .handled
        }
        .onKeyPress(.return) {
            if model.selected != nil {
                onPickResult?()
                return .handled
            }
            return .ignored
        }
        .onExitCommand {
            model.close()
        }
    }

    private func stepSelection(_ delta: Int) {
        guard !model.hits.isEmpty else { return }
        if let current = model.selectedID, let idx = model.hits.firstIndex(where: { $0.id == current }) {
            let next = max(0, min(model.hits.count - 1, idx + delta))
            model.selectedID = model.hits[next].id
        } else {
            model.selectedID = delta > 0 ? model.hits.first?.id : model.hits.last?.id
        }
    }

    private var searchHeader: some View {
        VStack(alignment:.leading,spacing:0) {
            if showEmbeddedField {
                LibrarySearchField(text:$model.query,large:false,focusRequest:model.focusRequest,onChange:{ model.refresh() },onCancel:{ model.close() })
                    .frame(height:28).padding(.horizontal,10).padding(.top,6).padding(.bottom,8)
            }
            ScrollView(.horizontal,showsIndicators:false) {
                HStack(spacing:6) {
                    Button(UXText.text("search.filter.starred")) { model.starred.toggle(); model.refresh() }.buttonStyle(.plain)
                        .modifier(SearchChip(active:model.starred)).accessibilityAddTraits(model.starred ? .isSelected : [])
                        .accessibilityIdentifier("search-starred")
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
                    } label: {
                        Text(dateText(model.date))
                            .foregroundStyle(model.date != .any ? CassiniTheme.onAccent : CassiniTheme.ink)
                    }.menuIndicator(.hidden).menuStyle(.borderlessButton).buttonStyle(.plain).fixedSize()
                        .modifier(SearchChip(active:model.date != .any)).accessibilityIdentifier("search-date")
                    Button(UXText.text("search.filter.recordedByMe")) { model.own.toggle(); model.refresh() }.buttonStyle(.plain)
                        .modifier(SearchChip(active:model.own)).accessibilityAddTraits(model.own ? .isSelected : [])
                        .accessibilityIdentifier("search-own")
                }.padding(.horizontal,10).padding(.bottom,8)
            }.frame(height:36)
            Text(model.count).font(.system(size:12,weight:.semibold)).foregroundStyle(CassiniTheme.ink2)
                .padding(.horizontal,18).padding(.bottom,6).accessibilityIdentifier("search-count")
        }.frame(maxWidth:.infinity,alignment:.leading)
    }

    private func row(_ hit: SearchHit, meeting: LibraryMeeting) -> some View {
        let selected = model.selectedID == hit.id
        let excerpt = hit.excerpt
        let compactTime = LibraryFormat.compactPosition(hit.positionMs, durationMs: meeting.durationMs, padMinutes: false, locale: UXText.locale)
        return Button {
            model.selectedID = hit.id
            onPickResult?()
        } label: {
            MeetingCard(isSelected: selected) {
                VStack(alignment:.leading,spacing:4) {
                    HStack(spacing:10) {
                        Text(meeting.title ?? UXText.text("library.untitled"))
                            .font(.system(size:13,weight:.semibold))
                            .foregroundStyle(CassiniTheme.ink)
                            .lineLimit(1)
                        Spacer(minLength:4)
                        Text(format.searchDate(meeting.meetingTime))
                            .font(.system(size:11.5))
                            .foregroundStyle(CassiniTheme.ink2)
                            .lineLimit(1)
                    }
                    (Text("“") + marked(excerpt.text,spans:excerpt.spans) + Text("”"))
                        .font(.system(size:13))
                        .foregroundStyle(CassiniTheme.ink)
                        .lineSpacing(3)
                        .fixedSize(horizontal:false,vertical:true)
                    Text(UXText.text("search.result.meta",["name":name(hit.speaker,meeting:meeting),"position":compactTime]))
                        .font(.system(size:11.5))
                        .monospacedDigit()
                        .foregroundStyle(CassiniTheme.ink2)
                }
            }
            .contentShape(Rectangle())
        }.buttonStyle(.plain).disabled(model.searching).accessibilityIdentifier("search-hit-" + hit.id)
            .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func name(_ id: String, meeting: LibraryMeeting) -> String { meeting.speaker(for:id)?.displayName ?? UXText.text("common.speaker.unnamed",["n":"1"]) }
    private func dateText(_ value: SearchDate) -> String {
        UXText.text(value == .any ? "search.filter.anyDate" : value == .today ? "search.filter.date.today" : value == .week ? "search.filter.date.week" : value == .month ? "search.filter.date.month" : "search.filter.date.year")
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

struct LibrarySearchPreviewPane: View {
    @State private var model = LibrarySearchModel.shared
    let hit: SearchHit
    let meeting: LibraryMeeting
    let format: LibraryFormat

    var body: some View {
        // The index prepared these turns off the main actor (#118 review).
        ScrollView {
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
        }.cassiniTopScrollEdge()
            .background(CassiniTheme.paneGround).accessibilityElement(children:.contain)
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
        field.focusRingType = .none
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
            let isFocused: Bool = {
                guard let window = controlView.window, let first = window.firstResponder else { return false }
                if first === controlView { return true }
                if let editor = (controlView as? NSControl)?.currentEditor(), first === editor { return true }
                return false
            }()
            let radius: CGFloat = controlSize == .large ? 7 : 6
            if isFocused {
                let focusPath = NSBezierPath(roundedRect: cellFrame.insetBy(dx: 1, dy: 1), xRadius: radius, yRadius: radius)
                CassiniTheme.nsField.setFill()
                focusPath.fill()
                CassiniTheme.nsAccent.setStroke()
                focusPath.lineWidth = 2
                focusPath.stroke()
            } else {
                let path = NSBezierPath(roundedRect: cellFrame.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius)
                CassiniTheme.nsField.setFill()
                path.fill()
                CassiniTheme.nsFieldLine.setStroke()
                path.lineWidth = 1
                path.stroke()
            }
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
        override func becomeFirstResponder() -> Bool {
            let became = super.becomeFirstResponder()
            needsDisplay = true
            return became
        }
        override func resignFirstResponder() -> Bool {
            let resigned = super.resignFirstResponder()
            needsDisplay = true
            return resigned
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
                guard !self.isHiddenOrHasHiddenAncestor, self.visibleRect.width > 0 else {
                    self.needsFocus = false
                    return
                }
                if let editor = self.currentEditor(), window.firstResponder === editor {
                    self.needsFocus = false
                    return
                }
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
        func controlTextDidBeginEditing(_ notification: Notification) {
            (notification.object as? NSView)?.needsDisplay = true
            parent.onBegin()
        }
        func controlTextDidEndEditing(_ notification: Notification) {
            (notification.object as? NSView)?.needsDisplay = true
        }
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

/// Focuses the currently mounted sidebar `NSSearchField` (native `.searchable` in wide windows
/// or embedded `LibrarySearchField` in narrow floating sidebars) and places the caret at the end.
@MainActor enum SidebarSearchFocus {
    static func focusLibrarySearchField(attemptsRemaining: Int = 2) {
        let window = NSApp.windows.first { $0.accessibilityIdentifier() == "cassini-library-window" } ?? NSApp.keyWindow
        if let window, focusMountedSearchField(in: window) {
            return
        }
        guard attemptsRemaining > 1 else { return }
        DispatchQueue.main.async {
            focusLibrarySearchField(attemptsRemaining: attemptsRemaining - 1)
        }
    }

    @discardableResult
    static func focusMountedSearchField(in window: NSWindow) -> Bool {
        if let field = findMountedSearchField(in: window.contentView) {
            return focus(field, in: window)
        }
        if let items = window.toolbar?.items {
            for item in items {
                if let searchItem = item as? NSSearchToolbarItem {
                    searchItem.beginSearchInteraction()
                    let field = searchItem.searchField
                    if field.window === window {
                        return focus(field, in: window)
                    }
                    return true
                }
            }
        }
        if let frameView = window.contentView?.superview,
           let field = findMountedSearchField(in: frameView) {
            return focus(field, in: window)
        }
        return false
    }

    private static func focus(_ field: NSSearchField, in window: NSWindow) -> Bool {
        guard window.makeFirstResponder(field) else { return false }
        if let editor = field.currentEditor() {
            editor.selectedRange = NSRange(location: (field.stringValue as NSString).length, length: 0)
        }
        return true
    }

    private static func findMountedSearchField(in root: NSView?) -> NSSearchField? {
        guard let root, !root.isHiddenOrHasHiddenAncestor else { return nil }
        if let field = root as? NSSearchField, field.isEnabled, field.isEditable {
            return field
        }
        for subview in root.subviews {
            if let found = findMountedSearchField(in: subview) {
                return found
            }
        }
        return nil
    }
}
