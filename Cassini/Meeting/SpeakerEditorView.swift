// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import CassiniLibrary

/// WP6: a single column dialog. Voice profiles are not yet prepared on Mac;
/// naming stays available without pretending that a voiceprint has been saved.
struct SpeakerEditorView:View {
    @State private var edit=MeetingRenameCoordinator.shared
    @FocusState private var nameFocused:Bool
    private var detail:MeetingDetailModel? {MeetingNavigation.shared.detail}
    var body:some View {
        VStack(alignment:.leading,spacing:18) {
            if let meeting=edit.meeting,let speaker=edit.selectedSpeaker {
                HStack(spacing:12) {
                    Text(String(speaker.displayName.prefix(1)).uppercased())
                        .font(.system(size:19,weight:.semibold))
                        .foregroundStyle(CassiniTheme.speakerInk(speaker))
                        .frame(width:44,height:44)
                        .background(CassiniTheme.speakerWash(speaker),in:RoundedRectangle(cornerRadius:12))
                    VStack(alignment:.leading,spacing:4) {
                        Text(speaker.displayName).font(.system(size:18,weight:.semibold))
                            .foregroundStyle(CassiniTheme.speakerInk(speaker)).lineLimit(2)
                            .accessibilityAddTraits(.isHeader)
                        if edit.speakerPreparing {ProgressView().controlSize(.small)}
                        else {
                            Text(UXText.text("speakers.talkTime",["talkTime":LibraryFormat.talkTime(edit.speakerTalkTime,locale:UXText.locale,language:UXText.language)]))
                                .foregroundStyle(CassiniTheme.ink2)
                        }
                    }
                    Spacer()
                    Button {
                        guard let detail else {return}
                        if detail.speakerSample.active {detail.speakerSample.cancel()}
                        else if let range=edit.speakerSampleRange {detail.playSpeakerSample(range)}
                    } label: {
                        Image(systemName:detail?.speakerSample.active == true ? "stop.fill" : "play.fill")
                            .frame(width:30,height:30)
                    }.buttonStyle(.plain)
                        .background(CassiniTheme.neutralPillFill,in:Circle())
                        .accessibilityLabel(UXText.text(detail?.speakerSample.active == true ? "common.stop" : "speakers.playSample"))
                        .disabled(edit.working || detail?.canPlay != true || edit.speakerSampleRange==nil)
                        .accessibilityIdentifier("speaker-play-sample")
                }
                if let quote=edit.speakerQuote {
                    HStack(spacing:12) {
                        RoundedRectangle(cornerRadius:2).fill(CassiniTheme.speakerInk(speaker)).frame(width:3)
                        Text(quote).foregroundStyle(CassiniTheme.ink).lineLimit(3)
                            .frame(maxWidth:.infinity,alignment:.leading)
                    }.fixedSize(horizontal:false,vertical:true).accessibilityIdentifier("speaker-quote")
                }
                VStack(alignment:.leading,spacing:7) {
                    Text(UXText.text("speakers.nameLabel")).foregroundStyle(CassiniTheme.ink2)
                    TextField("", text:$edit.name, prompt:Text(UXText.text("speakers.nameLabel")).foregroundStyle(CassiniTheme.ink3))
                        .textFieldStyle(.plain).padding(10)
                        .background(CassiniTheme.field,in:RoundedRectangle(cornerRadius:6))
                        .overlay(RoundedRectangle(cornerRadius:6).stroke(nameFocused ? CassiniTheme.accent : CassiniTheme.fieldLine,lineWidth:1))
                        .focused($nameFocused).disabled(edit.working)
                        .accessibilityLabel(UXText.text("speakers.nameLabel"))
                        .accessibilityIdentifier("speaker-name-field")
                        .onSubmit {if edit.canApply {edit.apply()}}
                }
                VStack(alignment:.leading,spacing:8) {
                    Text(UXText.text("common.savedVoices")).fontWeight(.semibold)
                    Text(UXText.text("savedVoices.empty")).foregroundStyle(CassiniTheme.ink2)
                        .frame(maxWidth:.infinity,alignment:.leading).padding(12)
                        .background(CassiniTheme.surface,in:RoundedRectangle(cornerRadius:8))
                }
                VStack(alignment:.leading,spacing:8) {
                    HStack(alignment:.top,spacing:12) {
                        VStack(alignment:.leading,spacing:5) {
                            Text(UXText.text("speakers.rememberVoice.title"))
                            Text(UXText.text(SpeakerEdits.normalizedName(edit.name) == nil ? "speakers.rememberVoice.cardBody.computer.unnamed" : "speakers.rememberVoice.cardBody.computer",
                                             ["name":SpeakerEdits.normalizedName(edit.name) ?? ""]))
                                .font(.system(size:12)).foregroundStyle(CassiniTheme.ink2)
                                .fixedSize(horizontal:false,vertical:true)
                        }
                        Spacer(minLength:0)
                        Toggle(UXText.text("speakers.rememberVoice.title"),isOn:.constant(false))
                            .labelsHidden().toggleStyle(.switch).controlSize(.small).disabled(true)
                            .accessibilityIdentifier("speaker-remember-voice")
                    }
                    Text(UXText.text("speakers.rememberVoice.notPrepared"))
                        .font(.system(size:12)).foregroundStyle(CassiniTheme.ink2)
                        .fixedSize(horizontal:false,vertical:true)
                }.padding(14).background(CassiniTheme.surface,in:RoundedRectangle(cornerRadius:8))
                if edit.speakerChangeFailed {
                    HStack(spacing:10) {
                        Text(UXText.text("speakers.changeFailed")).foregroundStyle(CassiniTheme.error)
                            .fixedSize(horizontal:false,vertical:true).accessibilityIdentifier("speaker-change-error")
                        Button(UXText.text("common.tryAgain")) {edit.retrySpeakerEdit()}.disabled(!edit.canRetrySpeakerEdit)
                    }.padding(12).background(CassiniTheme.errorTint,in:RoundedRectangle(cornerRadius:7))
                }
                HStack {
                    Menu(UXText.text("speakers.mergeInto")) {
                        ForEach(meeting.speakers.filter {$0.id != speaker.id},id:\.id) {other in
                            Button(other.displayName) {edit.mergeSpeaker(into:other.id)}
                                .accessibilityIdentifier("speaker-merge-into-"+other.id)
                        }
                    }.fixedSize().disabled(edit.working || meeting.speakers.count<2)
                        .accessibilityIdentifier("speaker-merge-menu")
                    Spacer(minLength:0)
                    if edit.working {ProgressView().controlSize(.small)}
                    Button(UXText.text("common.cancel")) {edit.cancel()}
                        .keyboardShortcut(.cancelAction).disabled(edit.working)
                    Button(UXText.text("speakers.saveName")) {edit.apply()}
                        .keyboardShortcut(.defaultAction).disabled(!edit.canApply)
                        .accessibilityIdentifier("speaker-save-name")
                }
            }
        }.font(.system(size:13)).foregroundStyle(CassiniTheme.ink)
            .padding(24).frame(width:470)
            .background(CassiniTheme.raised,in:RoundedRectangle(cornerRadius:12))
            .overlay(RoundedRectangle(cornerRadius:12).stroke(CassiniTheme.lineSoft,lineWidth:1))
            .shadow(color:CassiniTheme.shadow,radius:24,y:12)
            .accessibilityElement(children:.contain).accessibilityLabel(UXText.text("speakers.dialog.a11y"))
            .accessibilityAddTraits(.isModal).accessibilityIdentifier("speaker-editor")
            .onAppear {nameFocused=true}
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
            }.font(.system(size:13)).padding(14)
                .foregroundStyle(CassiniTheme.toastUsesInverse ? CassiniTheme.onInverse : CassiniTheme.ink)
                .buttonStyle(ToastButtonStyle(warning: false))
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
