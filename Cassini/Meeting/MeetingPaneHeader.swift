// SPDX-License-Identifier: GPL-3.0-or-later
import CassiniLibrary
import SwiftUI

struct MeetingPaneHeader: View {
    @Bindable var model: MeetingDetailModel
    let format: LibraryFormat
    @State private var rename = MeetingRenameCoordinator.shared
    private var meeting: LibraryMeeting { model.meeting }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(meeting.title ?? UXText.text("library.untitled"))
                    .font(.system(size: 22, weight: .bold)).textSelection(.enabled)
                    .accessibilityAddTraits(.isHeader).accessibilityIdentifier("meeting-title")
                Button { rename.show(meeting, presentation: .title) } label: { Image(systemName: "pencil").frame(width: 26, height: 26) }
                    .buttonStyle(.borderless).foregroundStyle(CassiniTheme.ink2)
                    .disabled(!rename.canRename(meeting))
                    .accessibilityLabel(UXText.text("meeting.renameEllipsis"))
                    .accessibilityIdentifier("meeting-rename")
                    .popover(isPresented: Binding(get: { rename.presentation == .title && rename.meeting?.folder == meeting.folder },
                                                  set: { if !$0 { rename.cancel() } })) { MeetingRenameView() }
            }
            Text(format.previewSubtitle(meeting.meetingTime, durationMs: meeting.durationMs, received: meeting.state.origin == .received))
                .foregroundStyle(CassiniTheme.ink2).accessibilityIdentifier("meeting-subtitle")
            if let badge = LibraryBadgeCatalog.presentation(for: meeting),
               ["needsAttention", "interrupted", "received"].contains(badge.kind) {
                CatalogStatusBadge(presentation: badge, isAnimating: false).accessibilityIdentifier("meeting-status-badge")
            }
            ScrollView(.horizontal) {
                HStack(spacing: 16) {
                    ForEach(meeting.speakers, id: \.id) { speaker in inlineSpeaker(speaker) }
                }.padding(.vertical, 2)
            }.scrollIndicators(.hidden).frame(height: 24)
        }.frame(maxWidth: .infinity, alignment: .leading)
            .foregroundStyle(CassiniTheme.ink).accessibilityIdentifier("meeting-heading")
    }

    private func inlineSpeaker(_ speaker: MeetingSpeaker) -> some View {
        let turns = model.listen.turns(of: speaker.id)
        let row = SpeakerRowPresentation(speaker: speaker, turns: turns, percent: model.shares[speaker.id, default: 0], language: UXText.language, locale: UXText.locale)
        let unnamed = CassiniTheme.speakerSlot(speaker) == 0
        let listening = model.listen.speaker.map { meeting.mergedInto[$0] ?? $0 } == speaker.id
        let canListen = model.canPlay && (listening || !turns.isEmpty)
        return HStack(spacing: 6) {
            Circle().fill(CassiniTheme.speakerInk(speaker))
                .frame(width: 7, height: 7).accessibilityHidden(true)
            if rename.canEditSpeakers(meeting) {
                Button { rename.showSpeaker(meeting, id: speaker.id) } label: {
                    Text(model.speakerName(speaker.id)).underline(unnamed, color: CassiniTheme.ink2.opacity(0.55))
                }.buttonStyle(.plain).accessibilityIdentifier("speaker-name-" + speaker.id)
                    .accessibilityLabel(row.accessibilityLabel)
            } else {
                Text(model.speakerName(speaker.id)).underline(unnamed, color: CassiniTheme.ink2.opacity(0.55))
                    .accessibilityIdentifier("speaker-name-label-" + speaker.id)
            }
            Button { model.toggleSpeakerListening(speaker.id) } label: {
                Image(systemName: listening ? "stop.fill" : "play.fill").font(.system(size: 10)).frame(width: 20, height: 20)
            }.buttonStyle(.borderless).foregroundStyle(CassiniTheme.ink2).disabled(!canListen)
                .accessibilityLabel(listening ? UXText.text("common.stop") : row.playAccessibilityLabel)
                .accessibilityIdentifier("speaker-listen-" + speaker.id)
            if speaker.provenance == .recognised {
                Text(UXText.text("common.autoTag")).font(.system(size: 10.5))
                    .foregroundStyle(CassiniTheme.ink2).padding(.horizontal, 4)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(CassiniTheme.tagStroke))
                    .help(UXText.text("common.autoTag.tooltip"))
            }
        }.fixedSize().accessibilityElement(children: .contain)
            .accessibilityIdentifier("speaker-row-" + speaker.id)
            .accessibilityLabel(row.accessibilityLabel + ", " + row.share)
            .help(row.accessibilityLabel)
            .contextMenu {
                Button(UXText.text("meeting.renameEllipsis")) { rename.showSpeaker(meeting, id: speaker.id) }
                    .disabled(!rename.canEditSpeakers(meeting))
                Button(UXText.text(listening ? "common.stop" : "speakers.listen")) { model.toggleSpeakerListening(speaker.id) }
                    .disabled(!canListen).accessibilityIdentifier("speaker-listen-menu-" + speaker.id)
                Text(row.share)
                if let caption = row.caption { Text(caption) }
            }
            .accessibilityAction(named: Text(UXText.text(listening ? "common.stop" : "speakers.listen"))) {
                if canListen { model.toggleSpeakerListening(speaker.id) }
            }
    }
}
