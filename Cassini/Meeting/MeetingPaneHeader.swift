// SPDX-License-Identifier: GPL-3.0-or-later
import CassiniLibrary
import SwiftUI

/// Inline meeting header (D-1172): title (24 pt bold), date and length, optional status badge,
/// and speaker names as one block closed by a hairline on every meeting. Scrolls away with the
/// transcript while the compact title and date appear in the toolbar.
struct MeetingPaneHeader: View {
    @Bindable var model: MeetingDetailModel
    let format: LibraryFormat
    @State private var rename = MeetingRenameCoordinator.shared
    @State private var dateTime = MeetingDateTimeCoordinator.shared
    @State private var editingTitle = false
    @State private var hoveringDate = false
    private var meeting: LibraryMeeting { model.meeting }

    var body: some View {
        let title = meeting.title ?? UXText.text("library.untitled")
        let subtitleParts = format.previewSubtitleParts(
            meeting.meetingTime,
            durationMs: meeting.durationMs,
            received: meeting.state.origin == .received,
            transcribedOnAnotherDevice: meeting.transcribedOnAnotherDevice
        )
        let canSetDate = dateTime.canSetDateTime(meeting)
        let visibleSpeakers = meeting.visibleSpeakers
        let showSpeakers = !TranscribingPresentation.isActive(meeting.state) && !visibleSpeakers.isEmpty

        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 6) {
                let canInlineRename: Bool = {
                    if rename.canRename(meeting) { return true }
                    #if DEBUG
                    if ProcessInfo.processInfo.environment["CASSINI_HOSTED_SCREENSHOTS"] == "1",
                       meeting.state.lifecycle == .saved, !meeting.metadataReadOnly {
                        return true
                    }
                    #endif
                    return false
                }()
                InlineEditableTitle(
                    title: title,
                    fontSize: 24,
                    weight: .bold,
                    singleLine: false,
                    canRename: canInlineRename,
                    identifier: "meeting-inline-title",
                    editorIdentifier: "meeting-inline-title-editor",
                    editing: $editingTitle,
                    onCommit: { newTitle in rename.renameInline(meeting, to: newTitle) }
                )
                HStack(spacing: 0) {
                    if canSetDate {
                        Button {
                            dateTime.show(meeting)
                        } label: {
                            Text(subtitleParts.date)
                                .foregroundStyle(CassiniTheme.ink2)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(hoveringDate ? CassiniTheme.ink.opacity(0.08) : Color.clear, in: RoundedRectangle(cornerRadius: 4))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, -4)
                        .onHover { hoveringDate = $0 }
                        .help(UXText.text("meeting.setDateTimeEllipsis"))
                        .accessibilityLabel(subtitleParts.date)
                        .accessibilityHint(UXText.text("meeting.setDateTimeEllipsis"))
                        .accessibilityIdentifier("meeting-inline-date")
                    } else {
                        Text(subtitleParts.date)
                            .foregroundStyle(CassiniTheme.ink2)
                    }
                    if !subtitleParts.suffix.isEmpty {
                        Text(subtitleParts.suffix)
                            .foregroundStyle(CassiniTheme.ink2)
                    }
                }
                .font(.system(size: 13))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("meeting-inline-subtitle")
            }
            if let badge = LibraryBadgeCatalog.presentation(for: meeting),
               ["needsAttention", "interrupted"].contains(badge.kind) {
                CatalogStatusBadge(presentation: badge, isAnimating: false)
                    .accessibilityIdentifier("meeting-status-badge")
            }
            if showSpeakers {
                SpeakerFlowLayout(horizontalSpacing: 18, verticalSpacing: 8) {
                    ForEach(visibleSpeakers, id: \.id) { speaker in
                        inlineSpeaker(speaker)
                    }
                }
                .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 14)
        .overlay(alignment: .bottom) {
            Rectangle().fill(CassiniTheme.cardStroke).frame(height: 1)
        }
        .padding(.bottom, 6)
        .foregroundStyle(CassiniTheme.ink)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("meeting-heading")
        .onChange(of: meeting.libraryKey) { _, _ in editingTitle = false }
    }

    private func inlineSpeaker(_ speaker: MeetingSpeaker) -> some View {
        let turns = model.listen.turns(of: speaker.id)
        let row = SpeakerRowPresentation(
            speaker: speaker,
            turns: turns,
            percent: model.shares[speaker.id, default: 0],
            language: UXText.language,
            locale: UXText.locale
        )
        let unnamed = CassiniTheme.speakerSlot(speaker) == 0
        let listening = model.listen.speaker.map { meeting.mergedInto[$0] ?? $0 } == speaker.id
        let canListen = model.canPlay && (listening || !turns.isEmpty)
        let labelView = HStack(spacing: 6) {
            Circle()
                .fill(CassiniTheme.speakerInk(speaker))
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)
            Text(model.speakerName(speaker.id))
                .font(.system(size: 13))
                .foregroundStyle(CassiniTheme.ink)
                .underline(unnamed, pattern: .dot, color: CassiniTheme.ink3)
        }

        return Group {
            if rename.canEditSpeakers(meeting) {
                Button { rename.showSpeaker(meeting, id: speaker.id) } label: { labelView }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("speaker-name-" + speaker.id)
                    .accessibilityLabel(row.accessibilityLabel)
            } else {
                labelView
                    .accessibilityIdentifier("speaker-name-label-" + speaker.id)
            }
        }
        .fixedSize()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("speaker-row-" + speaker.id)
        .accessibilityLabel(row.accessibilityLabel + ", " + row.share)
        .help(row.accessibilityLabel)
        .contextMenu {
            Button(UXText.text("meeting.renameEllipsis")) { rename.showSpeaker(meeting, id: speaker.id) }
                .disabled(!rename.canEditSpeakers(meeting))
            Button(UXText.text(listening ? "common.stop" : "speakers.listen")) { model.toggleSpeakerListening(speaker.id) }
                .disabled(!canListen)
                .accessibilityIdentifier("speaker-listen-menu-" + speaker.id)
            Text(row.share)
            if let caption = row.caption { Text(caption) }
        }
        .accessibilityAction(named: Text(UXText.text(listening ? "common.stop" : "speakers.listen"))) {
            if canListen { model.toggleSpeakerListening(speaker.id) }
        }
    }
}

/// Shared click-to-rename title control used in the meeting toolbar, inline meeting header,
/// and recording screen (D-1172, D-1200, L-110): fits the title plus 4 pt on each side, uses
/// macOS system blue focus ring and text selection, keeps the date line visible while editing,
/// saves on Return or any click outside the field, and restores the old name on Esc.
struct InlineEditableTitle: View {
    let title: String
    let fontSize: CGFloat
    let weight: Font.Weight
    let singleLine: Bool
    let canRename: Bool
    let identifier: String
    let editorIdentifier: String
    var maxWidth: CGFloat? = nil
    @Binding var editing: Bool
    let onCommit: (String) -> Void
    @State private var draft = ""
    @State private var hovering = false

    private var nsWeight: NSFont.Weight {
        switch weight {
        case .bold: return .bold
        case .semibold: return .semibold
        default: return .regular
        }
    }

    var body: some View {
        Group {
            if editing && canRename {
                Text(draft.isEmpty ? " " : draft)
                    .font(.system(size: fontSize, weight: weight))
                    .lineLimit(singleLine ? 1 : nil)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .opacity(0)
                    .accessibilityHidden(true)
                    .overlay {
                        InlineTitleTextField(
                            text: $draft,
                            font: NSFont.systemFont(ofSize: fontSize, weight: nsWeight),
                            singleLine: singleLine,
                            identifier: editorIdentifier,
                            onCommit: { value in
                                editing = false
                                onCommit(value)
                            },
                            onCancel: {
                                editing = false
                            }
                        )
                        .padding(.horizontal, 2)
                        .padding(.vertical, 1)
                    }
                    .background(CassiniTheme.surface, in: RoundedRectangle(cornerRadius: 4))
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(Color(nsColor: .controlAccentColor), lineWidth: 2)
                            .allowsHitTesting(false)
                    )
                    .frame(maxWidth: maxWidth, alignment: .leading)
                    .padding(.horizontal, -4)
            } else if canRename {
                Text(title)
                    .font(.system(size: fontSize, weight: weight))
                    .foregroundStyle(CassiniTheme.ink)
                    .lineLimit(singleLine ? 1 : nil)
                    .fixedSize(horizontal: false, vertical: !singleLine)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(hovering ? CassiniTheme.ink.opacity(0.08) : Color.clear, in: RoundedRectangle(cornerRadius: 4))
                    .contentShape(Rectangle())
                    .padding(.horizontal, -4)
                    .onHover { hovering = $0 }
                    .onTapGesture {
                        draft = title
                        editing = true
                    }
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier(identifier)
            } else {
                Text(title)
                    .font(.system(size: fontSize, weight: weight))
                    .foregroundStyle(CassiniTheme.ink)
                    .lineLimit(singleLine ? 1 : nil)
                    .fixedSize(horizontal: false, vertical: !singleLine)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier(identifier)
            }
        }
        .onChange(of: title) { _, newValue in
            if !editing { draft = newValue }
        }
        .onChange(of: canRename) { _, allowed in
            if !allowed { editing = false }
        }
    }
}

private struct InlineTitleTextField: NSViewRepresentable {
    @Binding var text: String
    let font: NSFont
    let singleLine: Bool
    let identifier: String
    let onCommit: (String) -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onCommit: onCommit, onCancel: onCancel)
    }

    func makeNSView(context: Context) -> FocusableInlineField {
        let field = FocusableInlineField()
        field.stringValue = text
        field.font = font
        field.textColor = CassiniTheme.nsInk
        field.isBezeled = false
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.isEditable = true
        field.isSelectable = true
        field.usesSingleLineMode = singleLine
        field.lineBreakMode = singleLine ? .byTruncatingTail : .byWordWrapping
        field.cell?.wraps = !singleLine
        field.cell?.isScrollable = singleLine
        field.delegate = context.coordinator
        field.setAccessibilityIdentifier(identifier)
        return field
    }

    func updateNSView(_ view: FocusableInlineField, context: Context) {
        context.coordinator.text = $text
        context.coordinator.onCommit = onCommit
        context.coordinator.onCancel = onCancel
        if view.stringValue != text { view.stringValue = text }
        view.font = font
        view.textColor = CassiniTheme.nsInk
    }

    final class FocusableInlineField: NSTextField {
        private var didFocus = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard !didFocus, let window else { return }
            didFocus = true
            DispatchQueue.main.async { [weak self, weak window] in
                guard let self, let window else { return }
                if window.makeFirstResponder(self) {
                    if let editor = self.currentEditor() as? NSTextView {
                        editor.selectedTextAttributes = [
                            .backgroundColor: NSColor.selectedTextBackgroundColor,
                            .foregroundColor: NSColor.selectedTextColor,
                        ]
                        editor.selectAll(nil)
                    }
                }
            }
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var text: Binding<String>
        var onCommit: (String) -> Void
        var onCancel: () -> Void
        private var finished = false

        init(text: Binding<String>, onCommit: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
            self.text = text
            self.onCommit = onCommit
            self.onCancel = onCancel
        }

        func controlTextDidChange(_ obj: Notification) {
            if let field = obj.object as? NSTextField {
                text.wrappedValue = field.stringValue
            }
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                guard !finished else { return true }
                finished = true
                onCommit(control.stringValue)
                return true
            }
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                guard !finished else { return true }
                finished = true
                onCancel()
                return true
            }
            return false
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            guard !finished, let field = obj.object as? NSTextField else { return }
            finished = true
            onCommit(field.stringValue)
        }
    }
}

private struct SpeakerFlowLayout: Layout {
    var horizontalSpacing: CGFloat = 18
    var verticalSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var usedWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                x = 0
                y += rowHeight + verticalSpacing
                rowHeight = 0
            }
            usedWidth = max(usedWidth, x + size.width)
            rowHeight = max(rowHeight, size.height)
            x += size.width + horizontalSpacing
        }
        return CGSize(width: proposal.width ?? usedWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + verticalSpacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            rowHeight = max(rowHeight, size.height)
            x += size.width + horizontalSpacing
        }
    }
}
