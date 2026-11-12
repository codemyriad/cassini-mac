// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import CassiniLibrary

struct SpeakerEditorView:View {
    @State private var edit=MeetingRenameCoordinator.shared
    private var detail:MeetingDetailModel? {MeetingNavigation.shared.detail}
    var body:some View {
        VStack(alignment:.leading,spacing:18) {
            Text(UXText.text("common.speakers")).font(.system(size:18,weight:.bold)).accessibilityAddTraits(.isHeader)
            if let meeting=edit.meeting,let speaker=edit.selectedSpeaker {
                Text(speaker.displayName).font(.headline).lineLimit(2)
                if edit.speakerPreparing {ProgressView().controlSize(.small)}
                else {
                    Text(UXText.text("speakers.talkTime",["talkTime":LibraryFormat.talkTime(edit.speakerTalkTime,locale:UXText.locale,language:UXText.language)]))
                        .foregroundStyle(CassiniTheme.secondaryInk)
                }
                HStack {
                    Text(UXText.text("speakers.nameLabel"))
                    TextField(UXText.text("speakers.nameLabel"),text:$edit.name).textFieldStyle(.roundedBorder)
                        .disabled(edit.working).accessibilityIdentifier("speaker-name-field")
                        .onSubmit {if edit.canApply {edit.apply()}}
                }
                HStack {
                    Button {
                        guard let detail else {return}
                        if detail.speakerSample.active {detail.speakerSample.cancel()}
                        else if let range=edit.speakerSampleRange {detail.playSpeakerSample(range)}
                    } label: {
                        Label(UXText.text(detail?.speakerSample.active == true ? "common.stop" : "speakers.playSample"),systemImage:detail?.speakerSample.active == true ? "stop.fill" : "play.fill")
                    }.disabled(edit.working || detail?.canPlay != true || edit.speakerSampleRange==nil)
                        .accessibilityIdentifier("speaker-play-sample")
                    Spacer()
                    Menu(UXText.text("speakers.mergeInto")) {
                        ForEach(meeting.speakers.filter {$0.id != speaker.id},id:\.id) { other in
                            Button(other.displayName) {edit.mergeSpeaker(into:other.id)}
                                .accessibilityIdentifier("speaker-merge-into-"+other.id)
                        }
                    }.disabled(edit.working || meeting.speakers.count<2).accessibilityIdentifier("speaker-merge-menu")
                }
            }
            if edit.speakerChangeFailed {
                Text(UXText.text("speakers.changeFailed")).foregroundStyle(CassiniTheme.secondaryInk).fixedSize(horizontal:false,vertical:true)
                Button(UXText.text("common.tryAgain")) {edit.retrySpeakerEdit()}.disabled(!edit.canRetrySpeakerEdit)
            }
            HStack {
                Spacer()
                if edit.working {ProgressView().controlSize(.small)}
                Button(UXText.text("common.cancel")) {edit.cancel()}.keyboardShortcut(.cancelAction).disabled(edit.working)
                Button(UXText.text("speakers.saveName")) {edit.apply()}.keyboardShortcut(.defaultAction).disabled(!edit.canApply)
                    .accessibilityIdentifier("speaker-save-name")
            }
        }.font(.system(size:13)).padding(24).frame(width:470)
            .accessibilityElement(children:.contain).accessibilityIdentifier("speaker-editor")
            .onDisappear {detail?.speakerSample.cancel()}
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
            }.font(.system(size:13)).padding(14).background(.regularMaterial,in:RoundedRectangle(cornerRadius:8)).padding()
        }
    }
}
