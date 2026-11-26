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
    private var meeting: LibraryMeeting { model.meeting }

    var body: some View {
        let title = meeting.title ?? UXText.text("library.untitled")
        let subtitle = format.previewSubtitle(
            meeting.meetingTime,
            durationMs: meeting.durationMs,
            received: meeting.state.origin == .received,
            transcribedOnAnotherDevice: meeting.transcribedOnAnotherDevice
        )
        let visibleSpeakers = meeting.visibleSpeakers
        let showSpeakers = !TranscribingPresentation.isActive(meeting.state) && !visibleSpeakers.isEmpty

        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(CassiniTheme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("meeting-inline-title")
                Text(subtitle)
                    .font(.system(size: 13))
                    .foregroundStyle(CassiniTheme.ink2)
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
        .padding(.bottom, 14)
        .overlay(alignment: .bottom) {
            Rectangle().fill(CassiniTheme.cardStroke).frame(height: 0.5)
        }
        .padding(.bottom, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .foregroundStyle(CassiniTheme.ink)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("meeting-heading")
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
