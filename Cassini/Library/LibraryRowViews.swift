// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import CassiniLibrary

struct LibraryMeetingRowView: View {
    let meeting: LibraryMeeting
    let isSelected: Bool
    let isContextMenuTarget: Bool
    let isStarred: Bool
    let format: LibraryFormat
    let isAnimatingBadges: Bool

    var body: some View {
        let presentation = LibraryBadgeCatalog.presentation(for: meeting)
        let showDuration = meeting.durationMs != nil && presentation?.kind != "recording" && presentation?.kind != "saving"
        let trailingMeta = Self.rowTrailingMeta(meeting, badgeKind: presentation?.kind)
        MeetingCard(isSelected: isSelected, isContextMenuTarget: isContextMenuTarget) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(meeting.title ?? UXText.text("library.untitled"))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(CassiniTheme.ink)
                        .lineLimit(1)
                    Spacer(minLength: 2)
                    if isStarred {
                        Image(systemName: "star.fill")
                            .font(.system(size: 10.5))
                            .foregroundStyle(CassiniTheme.accentInk)
                            .accessibilityLabel(UXText.text("library.row.starred.a11y"))
                            .accessibilityIdentifier("library-starred-" + meeting.libraryKey)
                    }
                    if showDuration, let durationMs = meeting.durationMs {
                        Text(LibraryFormat.meetingDuration(durationMs))
                            .font(.system(size: 11.5))
                            .foregroundStyle(CassiniTheme.ink2)
                            .monospacedDigit()
                            .fixedSize()
                    }
                }
                HStack(spacing: 6) {
                    if let start = meeting.meetingTime {
                        Text(format.rowTime(start))
                            .foregroundStyle(CassiniTheme.ink2)
                            .monospacedDigit()
                            .fixedSize()
                    }
                    if let presentation {
                        CatalogStatusBadge(presentation: presentation, isAnimating: isAnimatingBadges, onAccent: false)
                            .accessibilityAddTraits(.isStaticText)
                            .layoutPriority(1)
                        if let trailingMeta {
                            Text(trailingMeta)
                                .foregroundStyle(CassiniTheme.ink2)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                    } else if let trailingMeta {
                        if meeting.meetingTime != nil {
                            Text("·")
                                .foregroundStyle(CassiniTheme.ink2)
                                .accessibilityHidden(true)
                        }
                        Text(trailingMeta)
                            .foregroundStyle(CassiniTheme.ink2)
                            .lineLimit(1)
                    }
                }
                .font(.system(size: 11.5))
            }
        }
        .accessibilityIdentifier("meeting-card-" + meeting.libraryKey)
    }

    // L-51, L-53: duration sits top-right; line two shows time, optional status badge (no dot after a badge),
    // and speaker names (with a standalone middle dot when no badge is present).
    private static func rowTrailingMeta(_ meeting: LibraryMeeting, badgeKind: String?) -> String? {
        switch badgeKind {
        case "recording":
            return meeting.isBrowserCapture ? UXText.text("common.listeningInsideBrowser") : nil
        case "saving", "transcribing":
            return nil
        default:
            let names = LibraryFormat.rowMeta(durationMs: nil, names: meeting.speakerNames)
            return names.isEmpty ? nil : names
        }
    }
}

struct LibraryTransientImportRowView: View {
    let item: LibraryImportCoordinator.TransientItem
    let format: LibraryFormat
    let isAnimatingBadges: Bool
    let onDismiss: () -> Void

    private var failureDetail: String? {
        if case .failed(let detail) = item.state { return detail }
        return nil
    }

    private var isFailed: Bool { failureDetail != nil }

    var body: some View {
        let presentation = isFailed ? LibraryBadgeCatalog.needsAttentionPresentation : LibraryBadgeCatalog.importingPresentation
        MeetingCard(isSelected: false) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    Text(item.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(CassiniTheme.ink)
                        .lineLimit(1)
                    Spacer(minLength: 2)
                    if isFailed {
                        Button(UXText.text("common.done"), action: onDismiss)
                            .buttonStyle(.borderless)
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(CassiniTheme.accentInk)
                            .accessibilityIdentifier("dismiss-failed-import-" + item.fileName)
                    }
                }
                HStack(spacing: 6) {
                    Text(format.rowTime(item.startedAt))
                        .foregroundStyle(CassiniTheme.ink2)
                        .monospacedDigit()
                        .fixedSize()
                    if let presentation {
                        CatalogStatusBadge(presentation: presentation, isAnimating: isAnimatingBadges, onAccent: false)
                            .accessibilityAddTraits(.isStaticText)
                    }
                    Text(failureDetail ?? item.fileName)
                        .foregroundStyle(CassiniTheme.ink2)
                        .lineLimit(1)
                }
                .font(.system(size: 11.5))
            }
        }
        .id("import-" + item.id)
        .help(failureDetail ?? "")
        .contextMenu {
            if isFailed {
                Button(UXText.text("common.done"), action: onDismiss)
            }
        }
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets(top: 3, leading: 4, bottom: 3, trailing: 4))
        .accessibilityIdentifier((isFailed ? "failed-import-" : "importing-") + item.fileName)
    }
}
