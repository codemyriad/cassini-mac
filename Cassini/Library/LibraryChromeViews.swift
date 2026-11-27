// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import CassiniLibrary

struct LibraryWindowTitleModifier: ViewModifier {
    let savedDetail: MeetingDetailModel?
    let showsFirstRun: Bool
    let searchVisible: Bool
    let format: LibraryFormat

    @ViewBuilder
    func body(content: Content) -> some View {
        if let detail = savedDetail, !showsFirstRun, !searchVisible {
            let subtitle = format.previewSubtitle(
                detail.meeting.meetingTime,
                durationMs: detail.meeting.durationMs,
                received: detail.meeting.state.origin == .received,
                transcribedOnAnotherDevice: detail.meeting.transcribedOnAnotherDevice
            )
            content
                .navigationTitle(detail.meeting.title ?? UXText.text("library.untitled"))
                .navigationSubtitle(subtitle)
                .toolbar(removing: .title)
        } else {
            content
                .navigationTitle(UXText.text("app.name"))
                .toolbar(removing: .title)
        }
    }
}

/// Inline-editable meeting title and subtitle hosted in the detail toolbar's
/// leading `.navigation` placement. Clicking the title edits in place and routes
/// commits through `MeetingRenameCoordinator.renameInline` on both macOS 15 and 26.
struct MeetingWindowTitleView: View {
    let title: String
    let subtitle: String
    let canRename: Bool
    var maxWidth: CGFloat = 280
    let onCommit: (String) -> Void
    @State private var editing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            InlineEditableTitle(
                title: title,
                fontSize: 13,
                weight: .semibold,
                singleLine: true,
                canRename: canRename,
                identifier: "meeting-window-title",
                editorIdentifier: "meeting-window-title-editor",
                maxWidth: maxWidth,
                editing: $editing,
                onCommit: onCommit
            )
            if !editing {
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(CassiniTheme.secondaryInk)
                    .lineLimit(1)
                    .accessibilityIdentifier("meeting-window-subtitle")
            }
        }
        .frame(maxWidth: maxWidth, alignment: .leading)
        .onChange(of: title) { _, _ in editing = false }
        .onChange(of: canRename) { _, allowed in if !allowed { editing = false } }
    }
}

struct SidebarGlassCircleModifier: ViewModifier {
    func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: .circle)
        } else {
            content.background(CassiniTheme.chipFill, in: Circle())
        }
        #else
        content.background(CassiniTheme.chipFill, in: Circle())
        #endif
    }
}

struct SidebarBottomScrollEdgeModifier: ViewModifier {
    func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            content.scrollEdgeEffectStyle(.soft, for: .bottom)
        } else {
            content
        }
        #else
        content
        #endif
    }
}

struct UpdateReadyFooter: View {
    let updates: ApplicationUpdates
    var body: some View {
        if updates.readyWhenIdle {
            Text(UXText.text("updates.readyWhenIdle")).font(.system(size: 11.5)).foregroundStyle(CassiniTheme.ink2)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 18).padding(.vertical, 8)
                .accessibilityIdentifier("library-update-ready")
        }
    }
}

struct ConditionalNativeSidebarSearch: ViewModifier {
    let enabled: Bool
    @Binding var query: String
    @Binding var isPresented: Bool
    let prompt: String

    func body(content: Content) -> some View {
        if enabled {
            content.searchable(
                text: $query,
                isPresented: $isPresented,
                placement: .sidebar,
                prompt: prompt
            )
        } else {
            content
        }
    }
}
