// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import CassiniLibrary

/// D108 §6: Safari/Pages-style find bar tucked under the toolbar when open.
/// Three capsules (field with "2 of 3", previous/next, Done) in the sidebar search field's shape and grey fill.
struct MeetingFindBar: View {
    @Bindable var model: MeetingFindModel
    var onFocus: () -> Void = {}
    @FocusState private var focused: Bool

    private var capsuleFill: Color { CassiniTheme.ink.opacity(0.06) }

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(CassiniTheme.ink2)
                    .accessibilityHidden(true)
                TextField(UXText.text("meeting.find.placeholder"), text: $model.query)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .frame(minWidth: 80)
                    .layoutPriority(1)
                    .accessibilityLabel(UXText.text("meeting.find.placeholder"))
                    .accessibilityIdentifier("meeting-find")
                    .onSubmit { model.step(.next) }
                    .onExitCommand { model.close() }
                if model.searching {
                    ProgressView().controlSize(.mini).accessibilityIdentifier("meeting-find-searching")
                } else if !model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(model.status)
                        .font(.system(size: 11.5))
                        .monospacedDigit()
                        .foregroundStyle(CassiniTheme.ink2)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .layoutPriority(2)
                        .accessibilityIdentifier("meeting-find-count")
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 30)
            .frame(maxWidth: 420)
            .background(capsuleFill, in: Capsule())
            .overlay {
                if focused {
                    Capsule().stroke(CassiniTheme.accent.opacity(0.40), lineWidth: 3)
                }
            }

            HStack(spacing: 0) {
                Button { model.step(.previous) } label: {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 30, height: 26)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel(UXText.text("mac.legacy.previousMatch"))
                .help(UXText.text("mac.legacy.previousMatch"))
                .accessibilityIdentifier("meeting-find-previous")
                .disabled(model.matches.isEmpty)

                Rectangle()
                    .fill(CassiniTheme.cardStroke)
                    .frame(width: 0.5, height: 14)
                    .accessibilityHidden(true)

                Button { model.step(.next) } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 30, height: 26)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel(UXText.text("mac.legacy.nextMatch"))
                .help(UXText.text("mac.legacy.nextMatch"))
                .accessibilityIdentifier("meeting-find-next")
                .disabled(model.matches.isEmpty)
            }
            .padding(.horizontal, 3)
            .frame(height: 28)
            .background(capsuleFill, in: Capsule())

            Spacer(minLength: 8)

            Button { model.close() } label: {
                Text(UXText.text("common.done"))
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(CassiniTheme.ink)
                    .padding(.horizontal, 14)
                    .frame(height: 28)
                    .background(capsuleFill, in: Capsule())
                    .contentShape(Capsule())
            }
            .accessibilityIdentifier("meeting-find-done")
        }
        .font(.system(size: 13))
        .buttonStyle(.plain)
        .padding(.top, 8)
        .padding(.bottom, 14)
        .padding(.leading, 20)
        .padding(.trailing, 14)
        .background(.bar)
        .overlay(alignment: .bottom) {
            Rectangle().fill(CassiniTheme.cardStroke).frame(height: 0.5)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("meeting-find-bar")
        .onChange(of: model.focusRequest) { _, _ in handleFocusRequest() }
        .onAppear { handleFocusRequest() }
        .onChange(of: focused) { _, value in
            model.focused = value
            if value { onFocus() }
        }
        .onChange(of: model.query) { _, query in if !query.isEmpty { onFocus() } }
        .onDisappear { model.focused = false }
    }

    private func handleFocusRequest() {
        if model.consumeFocusRequest() { focused = true }
    }
}
