// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import CassiniLibrary

struct SpeakerEditorView: View {
    @State private var edit = MeetingRenameCoordinator.shared
    @FocusState private var nameFocused: Bool
    private var detail: MeetingDetailModel? { MeetingNavigation.shared.detail }

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            if let speaker = edit.selectedSpeaker {
                heading(speaker)
                if let quote = edit.speakerQuote { sampleQuote(quote) }
                nameField
                sampleButton
            }
            if edit.speakerChangeFailed { failureNotice }
            footer
        }.font(.system(size: 13)).foregroundStyle(CassiniTheme.ink).padding(24).frame(width: 540)
            .background(CassiniTheme.raised).presentationCornerRadius(12)
            .defaultFocus($nameFocused, true).onAppear { nameFocused = true }
            .accessibilityElement(children: .contain).accessibilityLabel(UXText.text("speakers.dialog.a11y"))
            .accessibilityIdentifier("speaker-editor")
            .onDisappear { detail?.speakerSample.cancel() }
    }
    private func heading(_ speaker: MeetingSpeaker) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(speaker.displayName).font(.system(size: 17, weight: .bold)).foregroundStyle(CassiniTheme.ink).lineLimit(2)
                .accessibilityAddTraits(.isHeader).accessibilityIdentifier("speaker-editor-heading")
            if edit.speakerPreparing { ProgressView().controlSize(.small) }
            else {
                Text(UXText.text("speakers.talkTime", ["talkTime": LibraryFormat.talkTime(edit.speakerTalkTime, locale: UXText.locale, language: UXText.language)]))
                    .font(.system(size: 11.5)).foregroundStyle(CassiniTheme.ink2)
            }
        }
    }
    private func sampleQuote(_ quote: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Rectangle().fill(CassiniTheme.tagStroke).frame(width: 3)
            Text("“" + quote + "”").foregroundStyle(CassiniTheme.ink2).lineSpacing(4).lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading).accessibilityIdentifier("speaker-quote")
        }.fixedSize(horizontal: false, vertical: true)
    }
    private var nameField: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(UXText.text("speakers.nameLabel")).fontWeight(.semibold)
            TextField("", text: $edit.name, prompt: Text(UXText.text("speakers.nameLabel")).foregroundStyle(CassiniTheme.ink3))
                .textFieldStyle(.plain).padding(.horizontal, 10).frame(height: 32)
                .background(CassiniTheme.field, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(nameFocused ? CassiniTheme.accent : CassiniTheme.fieldLine,
                                                               lineWidth: nameFocused ? 1.5 : 1))
                .disabled(edit.working).focused($nameFocused).accessibilityIdentifier("speaker-name-field")
                .onSubmit { if edit.canApply { edit.apply() } }
        }
    }
    private var sampleButton: some View {
        Button {
            guard let detail else { return }
            if detail.speakerSample.active { detail.speakerSample.cancel() }
            else if let range = edit.speakerSampleRange { detail.playSpeakerSample(range) }
        } label: {
            Label(UXText.text(detail?.speakerSample.active == true ? "common.stop" : "speakers.playSample"),
                  systemImage: detail?.speakerSample.active == true ? "stop.fill" : "play.fill")
        }.disabled(edit.working || detail?.canPlay != true || edit.speakerSampleRange == nil)
            .accessibilityIdentifier("speaker-play-sample")
    }
    private var failureNotice: some View {
        HStack(spacing: 10) {
            Text(UXText.text("speakers.changeFailed")).foregroundStyle(CassiniTheme.error).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("speaker-change-error")
            Spacer(minLength: 0)
            Button(UXText.text("common.tryAgain")) { edit.retrySpeakerEdit() }.disabled(!edit.canRetrySpeakerEdit)
        }.padding(12).background(CassiniTheme.errorTint, in: RoundedRectangle(cornerRadius: 7))
    }
    private var footer: some View {
        HStack(spacing: 8) {
            if let meeting = edit.meeting, let speaker = edit.selectedSpeaker { mergeMenu(meeting, speaker: speaker) }
            Spacer(minLength: 12)
            if edit.working { ProgressView().controlSize(.small) }
            Button(UXText.text("common.cancel")) { edit.cancel() }.keyboardShortcut(.cancelAction).disabled(edit.working)
                .buttonStyle(.plain).padding(.horizontal, 12).frame(height: 32)
                .background(CassiniTheme.neutralPillFill, in: RoundedRectangle(cornerRadius: 8))
            Button(UXText.text("speakers.saveName")) { edit.apply() }.keyboardShortcut(.defaultAction).disabled(!edit.canApply)
                .buttonStyle(.borderedProminent).controlSize(.large).tint(CassiniTheme.accentStrong)
                .accessibilityIdentifier("speaker-save-name")
        }
    }
    private func mergeMenu(_ meeting: LibraryMeeting, speaker: MeetingSpeaker) -> some View {
        Menu(UXText.text("speakers.mergeInto")) {
            ForEach(meeting.speakers.filter { $0.id != speaker.id }, id: \.id) { other in
                Button(other.displayName) { edit.mergeSpeaker(into: other.id) }
                    .accessibilityIdentifier("speaker-merge-into-" + other.id)
            }
        }.menuStyle(.borderlessButton).fixedSize().foregroundStyle(CassiniTheme.ink)
            .padding(.horizontal, 12).frame(height: 32).contentShape(RoundedRectangle(cornerRadius: 8))
            .background(CassiniTheme.neutralPillFill, in: RoundedRectangle(cornerRadius: 8))
            .disabled(edit.working || meeting.speakers.count < 2).accessibilityIdentifier("speaker-merge-menu")
    }
}
struct SpeakerEditFailureNotice:View {
    @State private var edit=MeetingRenameCoordinator.shared
    var body:some View {
        if edit.speakerChangeFailed && edit.presentation==nil {
            HStack {
                Text(UXText.text("speakers.changeFailed"))
                Button(UXText.text("common.tryAgain")) {edit.retrySpeakerEdit()}.disabled(!edit.canEditSpeakers(edit.meeting))
                Button {edit.dismissSpeakerFailure()} label: {Image(systemName:"xmark")}.accessibilityLabel(UXText.text("common.close"))
            }.font(.system(size:13)).padding(14)
                .foregroundStyle(CassiniTheme.toastUsesInverse ? CassiniTheme.onInverse : CassiniTheme.ink)
                .background {
                    if CassiniTheme.toastUsesInverse {
                        RoundedRectangle(cornerRadius:8).fill(CassiniTheme.inverse)
                            .shadow(color:CassiniTheme.shadow,radius:6,y:2)
                    } else {
                        RoundedRectangle(cornerRadius:8).fill(.regularMaterial)
                    }
                }
                .tint(CassiniTheme.toastUsesInverse ? CassiniTheme.inverseAccent : nil)
                .padding()
        }
    }
}
