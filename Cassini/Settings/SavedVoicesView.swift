// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import CassiniLibrary
import CassiniModels

struct SavedVoicesSettingsRow: View {
    @State private var voices=SavedVoicesController.shared
    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            Button { SettingsNavigation.shared.savedVoices=true } label: {
                HStack {
                    VStack(alignment:.leading,spacing:5) {
                        Text(UXText.text("common.savedVoices")).fontWeight(.semibold)
                        Text(UXText.text(voices.voices.isEmpty ? "settings.transcription.savedVoices.summary.none":"settings.transcription.savedVoices.summary",["n":String(voices.voices.count)]))
                            .font(.system(size:12)).foregroundStyle(CassiniTheme.ink2)
                    }
                    Spacer()
                    Image(systemName:"chevron.right").accessibilityHidden(true)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityIdentifier("settings-saved-voices")
        }
    }
}
struct SavedVoicesView: View {
    @State private var voices=SavedVoicesController.shared
    @State private var deleting: SavedVoice?
    @State private var forgetAll=false
    @State private var renaming: SavedVoice?
    @State private var name=""
    var body: some View {
        ScrollView {
            VStack(alignment:.leading,spacing:20) {
                Button { SettingsNavigation.shared.savedVoices=false } label: {
                    Label(UXText.text("savedVoices.back"),systemImage:"chevron.left")
                }.buttonStyle(.plain).foregroundStyle(CassiniTheme.accent)
                    .accessibilityIdentifier("saved-voices-back")
                Text(UXText.text("savedVoices.privacy.mac")).foregroundStyle(CassiniTheme.ink2).fixedSize(horizontal:false,vertical:true)
                if voices.readOnly { Text(UXText.text("savedVoices.newerVersion")).foregroundStyle(CassiniTheme.warnInk) }
                if voices.voices.isEmpty {
                    Text(UXText.text("savedVoices.empty")).foregroundStyle(CassiniTheme.ink2).padding(.vertical,16)
                        .accessibilityIdentifier("saved-voices-empty")
                } else {
                    VStack(spacing:0) {
                        ForEach(voices.voices) { voice in
                            voiceRow(voice)
                            if voice.id != voices.voices.last?.id { Divider() }
                        }
                    }.background(CassiniTheme.surface,in:RoundedRectangle(cornerRadius:12))
                }
                if !voices.voices.isEmpty {
                    Button(UXText.text("savedVoices.forgetEveryone"),role:.destructive) { forgetAll=true }
                        .disabled(voices.readOnly || voices.busy).accessibilityIdentifier("saved-voices-forget-everyone")
                }
                Text(UXText.text("savedVoices.howToAdd.short")).font(.system(size:12)).foregroundStyle(CassiniTheme.ink2)
                    .fixedSize(horizontal:false,vertical:true).accessibilityIdentifier("saved-voices-how-to-add")
                if let message=voices.message { Text(message).foregroundStyle(CassiniTheme.warnInk).fixedSize(horizontal:false,vertical:true) }
            }.padding(24).frame(maxWidth:.infinity,alignment:.leading)
        }.background(CassiniTheme.windowGround)
            .navigationTitle(UXText.text("common.savedVoices"))
            .navigationBarBackButtonHidden(true)
            .accessibilityIdentifier(voices.loaded ? "saved-voices-ready":"saved-voices-loading")
            .task(id:LibraryStore.shared.revision) { await voices.refresh() }
            .onDisappear { voices.stopSample() }
            .sheet(isPresented:$voices.enrollmentPresented,onDismiss:{ voices.cancelEnrollment() }) { VoiceEnrollmentView() }
            .sheet(item:$renaming) { voice in
                VStack(alignment:.leading,spacing:18) {
                    Text(UXText.text("savedVoices.rename.title")).font(.headline)
                    TextField(UXText.text("speakers.nameLabel"),text:$name)
                    if !SavedVoicesStore.validName(name) { Text(UXText.text("savedVoices.rename.blank")).foregroundStyle(CassiniTheme.warnInk) }
                    HStack { Spacer(); Button(UXText.text("common.cancel")) { renaming=nil }.keyboardShortcut(.cancelAction)
                        Button(UXText.text("savedVoices.rename.save")) { voices.rename(voice,name:name); renaming=nil }
                            .keyboardShortcut(.defaultAction).disabled(!SavedVoicesStore.validName(name)) }
                }.padding(24).frame(width:380)
            }
            .confirmationDialog(UXText.text("confirm.deleteVoiceProfile.title",["name":deleting?.name ?? ""]),
                isPresented:Binding(get:{ deleting != nil },set:{ if !$0 { deleting=nil } }),titleVisibility:.visible) {
                    Button(UXText.text("confirm.deleteVoiceProfile.primary"),role:.destructive) { if let deleting { voices.forget(deleting) }; deleting=nil }
                    Button(UXText.text("common.cancel"),role:.cancel) { deleting=nil }
                } message: { Text(UXText.text("confirm.deleteVoiceProfile.body",["name":deleting?.name ?? ""])) }
            .confirmationDialog(UXText.text("confirm.forgetEveryone.title"),isPresented:$forgetAll,titleVisibility:.visible) {
                Button(UXText.text("confirm.forgetEveryone.primary"),role:.destructive) { voices.forgetEveryone() }
                Button(UXText.text("common.cancel"),role:.cancel) {}
            } message: { Text(UXText.text("confirm.forgetEveryone.body")) }
    }
    private func voiceRow(_ voice: SavedVoice) -> some View {
        HStack(alignment:.top,spacing:12) {
            Text(String(voice.name.prefix(1)).localizedUppercase).font(.system(size:12,weight:.semibold))
                .foregroundStyle(CassiniTheme.savedVoiceInk(saveOrder:voice.colourSlot))
                .frame(width:30,height:30).background(CassiniTheme.savedVoiceWash(saveOrder:voice.colourSlot),in:Circle())
                .accessibilityHidden(true)
            VStack(alignment:.leading,spacing:5) {
                Text(voice.name).fontWeight(.semibold)
                Text(UXText.text("savedVoices.row.meta",[
                    "meetingCount":UXText.text("savedVoices.row.meetingCount",["n":String(voices.meetingCounts[voice.id] ?? 0)]),
                    "confirmedSpeech":LibraryFormat.confirmedSpeech(Int64(voice.seconds*1000),locale:UXText.locale,language:UXText.language)]))
                    .font(.system(size:12)).foregroundStyle(CassiniTheme.ink2)
                if voice.stale {
                    Text(UXText.text("savedVoices.row.stale")).font(.system(size:12)).foregroundStyle(CassiniTheme.warnInk)
                        .fixedSize(horizontal:false,vertical:true).accessibilityIdentifier("saved-voice-stale-" + voice.id)
                }
            }
            Spacer()
            Button { voices.play(voice) } label: { Image(systemName:voices.playing == voice.id ? "stop.fill":"play.fill") }
                .accessibilityLabel(UXText.text(voices.playing == voice.id ? "savedVoices.row.stopSample":"savedVoices.row.play",["name":voice.name]))
                .disabled(voices.playable(voice) == nil).accessibilityIdentifier("saved-voice-play-" + voice.id)
            Menu {
                Button(UXText.text("savedVoices.row.playSampleMenu")) { voices.play(voice) }
                    .disabled(voices.playable(voice) == nil)
                Button(UXText.text("savedVoices.row.rename")) { name=voice.name; renaming=voice }.disabled(voices.busy || voices.readOnly)
                Button(UXText.text("savedVoices.row.forgetEllipsis"),role:.destructive) { deleting=voice }.disabled(voices.busy || voices.readOnly)
            } label: { Image(systemName:"ellipsis").frame(width:24,height:24) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .accessibilityLabel(UXText.text("savedVoices.row.options.a11y",["name":voice.name]))
                .accessibilityIdentifier("saved-voice-options-" + voice.id)
        }.padding(.horizontal,14).padding(.vertical,10).accessibilityElement(children:.contain)
    }
}
struct VoiceEnrollmentView: View {
    @State private var voices=SavedVoicesController.shared
    var body: some View {
        VStack(alignment:.leading,spacing:16) {
            Text(UXText.text("voices.enroll.title")).font(.title2).fontWeight(.semibold)
            Text(UXText.text("voices.enroll.instructions")).fixedSize(horizontal:false,vertical:true)
            TextField(UXText.text("speakers.nameLabel"),text:$voices.enrollmentName).disabled(voices.busy)
                .onChange(of:voices.enrollmentName) { _,_ in voices.selectedExistingID=nil }
            let duplicates=VoiceSelection.matchingName(voices.enrollmentName,voices:voices.voices)
            if let duplicate=duplicates.first {
                Text(UXText.text("speakers.duplicate.notice",["name":duplicate.name]))
                HStack {
                    Button(UXText.text("speakers.duplicate.samePerson")) { voices.selectedExistingID=duplicate.id }
                    Button(UXText.text("speakers.duplicate.someoneElse")) { voices.selectedExistingID=nil }
                    if voices.selectedExistingID == duplicate.id { Image(systemName:"checkmark").accessibilityLabel(duplicate.name) }
                }
            }
            Text(UXText.text("voices.enroll.testPhraseLabel")).fontWeight(.semibold)
            Text(UXText.text("voices.enroll.testPhrase")).padding(14).background(CassiniTheme.surface,in:RoundedRectangle(cornerRadius:8))
            if !voices.modelReady {
                Button(UXText.text("models.download")) { voices.download() }.disabled(voices.downloading)
            }
            if voices.recording { Text(UXText.text("voices.enroll.recording")) }
            if voices.sampleReady { Text(UXText.text("voices.enroll.ready")) }
            if let message=voices.message { Text(message).foregroundStyle(CassiniTheme.warnInk) }
            HStack {
                Button(UXText.text(voices.recording ? "common.stop":"voices.enroll.record")) {
                    if voices.recording { voices.finishRecording() } else { voices.startRecording() }
                }.disabled(voices.busy || !voices.modelReady)
                if voices.busy { ProgressView().controlSize(.small) }
                Spacer()
                Button(UXText.text("common.cancel")) { voices.cancelEnrollment(); voices.enrollmentPresented=false }.keyboardShortcut(.cancelAction).disabled(voices.savingEnrollment)
                Button(UXText.text("voices.enroll.save")) { voices.saveEnrollment() }
                    .disabled(!voices.sampleReady || voices.busy || !SavedVoicesStore.validName(voices.enrollmentName)).keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width:490).fixedSize(horizontal:false,vertical:true)
            .interactiveDismissDisabled(voices.busy)
    }
}

struct SavedVoiceModelRow: View {
    @State private var voices = SavedVoicesController.shared
    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            HStack {
                SettingsDescription("models.recogniseVoices.name", "models.recogniseVoices.description.short")
                Spacer()
                if voices.downloading {
                    ProgressView(value:voices.progress).frame(width:100)
                    Button(UXText.text("common.cancel")) { voices.cancelDownload() }
                } else if voices.modelReady {
                    Text(UXText.text("models.statusWithSize",["status":UXText.text("models.status.on"),"size":LibraryFormat.size(bytes:voices.installedBytes)])).foregroundStyle(CassiniTheme.ink2)
                    Button(UXText.text("models.remove")) { voices.removeModel() }.disabled(voices.busy)
                } else {
                    if voices.downloadBytes > 0 { Text(UXText.text("format.size.download",["size":LibraryFormat.size(bytes:voices.downloadBytes)])).foregroundStyle(CassiniTheme.ink2) }
                    Button(UXText.text("models.download")) { voices.download() }.disabled(voices.busy)
                }
            }
            if let message = voices.message {
                Text(message).font(.caption).foregroundStyle(CassiniTheme.warnInk)
                    .accessibilityIdentifier("settings-voice-model-message")
            }
        }
    }
}
