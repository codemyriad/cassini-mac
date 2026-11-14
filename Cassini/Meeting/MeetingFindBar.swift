// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import CassiniLibrary

struct MeetingFindBar: View {
    @Bindable var model: MeetingFindModel
    var onFocus: () -> Void = {}
    @FocusState private var focused: Bool
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(CassiniTheme.ink2).accessibilityHidden(true)
            TextField(UXText.text("meeting.find.placeholder"), text: $model.query)
                .textFieldStyle(.plain).focused($focused).frame(minWidth: 80).layoutPriority(1)
                .accessibilityLabel(UXText.text("meeting.find.placeholder"))
                .accessibilityIdentifier("meeting-find")
                .onSubmit { model.step(.next) }
                .onExitCommand { model.query = ""; focused = false }
            if model.searching {
                ProgressView().controlSize(.mini).accessibilityIdentifier("meeting-find-searching")
            } else if !model.query.isEmpty {
                Text(model.status).font(.system(size: 11.5)).foregroundStyle(CassiniTheme.ink2)
                    .lineLimit(1).fixedSize(horizontal:true,vertical:false).layoutPriority(2)
                    .accessibilityIdentifier("meeting-find-count")
                Button { model.step(.previous) } label: { Image(systemName: "chevron.up") }
                    .accessibilityLabel(UXText.text("mac.legacy.previousMatch"))
                    .accessibilityIdentifier("meeting-find-previous").disabled(model.matches.isEmpty)
                Button { model.step(.next) } label: { Image(systemName: "chevron.down") }
                    .accessibilityLabel(UXText.text("mac.legacy.nextMatch"))
                    .accessibilityIdentifier("meeting-find-next").disabled(model.matches.isEmpty)
                Button { model.query = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .accessibilityLabel(UXText.text("common.done"))
                    .accessibilityIdentifier("meeting-find-clear")
            }
        }.font(.system(size: 12.5)).buttonStyle(.borderless)
            .padding(.horizontal, 9).frame(height: 28)
            .background(CassiniTheme.field, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(CassiniTheme.fieldLine, lineWidth: 1))
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
