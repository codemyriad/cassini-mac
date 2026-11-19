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
        GeometryReader { proxy in
            ScrollView {
                VStack(alignment:.leading,spacing:12) {
                    HStack(spacing:8) {
                        Button { SettingsNavigation.shared.savedVoices=false } label: {
                            Image(systemName:"chevron.left")
                                .font(.system(size:12,weight:.semibold))
                                .frame(width:26,height:24)
                                .background(CassiniTheme.chipFill,in:RoundedRectangle(cornerRadius:6))
                        }.buttonStyle(.plain).foregroundStyle(CassiniTheme.ink)
                            .accessibilityLabel(UXText.text("savedVoices.back"))
                            .accessibilityIdentifier("saved-voices-back")
                        Text(UXText.text("common.savedVoices"))
                            .font(.system(size:15,weight:.semibold))
                    }
                    if voices.readOnly { Text(UXText.text("savedVoices.newerVersion")).foregroundStyle(CassiniTheme.warnInk) }
                    let staleVoices=voices.voices.filter(\.stale)
                    if !staleVoices.isEmpty {
                        let names=LibraryFormat(locale:UXText.locale,language:UXText.language).list(staleVoices.map(\.name))
                        VStack(alignment:.leading,spacing:3) {
                            Text(UXText.text("savedVoices.stale.title",["n":String(staleVoices.count)]))
                                .font(.system(size:13,weight:.semibold)).foregroundStyle(CassiniTheme.warnInk)
                            Text(UXText.text("savedVoices.stale.body",["name":names]))
                                .font(.system(size:12)).foregroundStyle(CassiniTheme.ink).fixedSize(horizontal:false,vertical:true)
                        }
                        .padding(.horizontal,14).padding(.vertical,12)
                        .frame(maxWidth:.infinity,alignment:.leading)
                        .background(CassiniTheme.warnTint,in:RoundedRectangle(cornerRadius:10))
                        .accessibilityElement(children:.contain)
                        .accessibilityIdentifier("saved-voices-stale-notice")
                    }
                    if voices.voices.isEmpty {
                        Spacer(minLength:16)
                        VStack(spacing:8) {
                            Text(UXText.text("savedVoices.empty"))
                                .font(.system(size:19,weight:.bold))
                                .accessibilityIdentifier("saved-voices-empty")
                            Text(UXText.text("savedVoices.empty.body"))
                                .font(.system(size:13)).foregroundStyle(CassiniTheme.ink2)
                                .multilineTextAlignment(.center).fixedSize(horizontal:false,vertical:true)
                            Button { voices.beginEnrollment() } label: {
                                Text(UXText.text("voices.enroll.addAction"))
                                    .font(.system(size:13,weight:.medium))
                                    .padding(.horizontal,14).frame(height:28)
                                    .foregroundStyle(CassiniTheme.onAccent)
                                    .background(CassiniTheme.accentStrong,in:RoundedRectangle(cornerRadius:6))
                            }
                            .buttonStyle(.plain)
                            .disabled(voices.readOnly || voices.busy)
                            .accessibilityIdentifier("saved-voices-add")
                            .padding(.top,10)
                        }
                        .frame(maxWidth:380)
                        .frame(maxWidth:.infinity)
                        Spacer(minLength:16)
                    } else {
                        VStack(alignment:.leading,spacing:8) {
                            HStack {
                                Text(UXText.text("savedVoices.peopleCount",["n":String(voices.voices.count)]))
                                    .font(.system(size:13,weight:.semibold))
                                Spacer()
                                Button { voices.beginEnrollment() } label: {
                                    HStack(spacing:4) {
                                        Image(systemName:"plus").font(.system(size:11,weight:.semibold)).accessibilityHidden(true)
                                        Text(UXText.text("voices.enroll.addAction"))
                                    }
                                    .font(.system(size:13))
                                    .foregroundStyle(CassiniTheme.accentInk)
                                }
                                .buttonStyle(.plain)
                                .disabled(voices.readOnly || voices.busy)
                                .accessibilityIdentifier("saved-voices-add")
                            }
                            .padding(.horizontal,2)
                            VStack(spacing:0) {
                                ForEach(voices.voices) { voice in
                                    voiceRow(voice)
                                    if voice.id != voices.voices.last?.id { Divider().padding(.leading,56) }
                                }
                            }
                            .background(CassiniTheme.surface,in:RoundedRectangle(cornerRadius:10))
                            .overlay { RoundedRectangle(cornerRadius:10).stroke(CassiniTheme.lineSoft) }
                            Text(UXText.text("savedVoices.caption")).font(.system(size:12)).foregroundStyle(CassiniTheme.ink2)
                                .fixedSize(horizontal:false,vertical:true).padding(.horizontal,2).padding(.top,4)
                                .accessibilityIdentifier("saved-voices-how-to-add")
                            Button(UXText.text("savedVoices.forgetEveryone"),role:.destructive) { forgetAll=true }
                                .disabled(voices.readOnly || voices.busy).padding(.top,2)
                                .accessibilityIdentifier("saved-voices-forget-everyone")
                        }
                        .padding(.top,8)
                        Spacer(minLength:16)
                    }
                    if let message=voices.message { Text(message).foregroundStyle(CassiniTheme.warnInk).fixedSize(horizontal:false,vertical:true) }
                    HStack(spacing:6) {
                        Image(systemName:"lock").font(.system(size:11,weight:.medium)).foregroundStyle(CassiniTheme.accentInk).accessibilityHidden(true)
                        Text(UXText.text("savedVoices.footnote.mac")).font(.system(size:12)).foregroundStyle(CassiniTheme.ink2)
                    }
                    .frame(maxWidth:.infinity,alignment:.center)
                    .accessibilityElement(children:.combine)
                    .accessibilityIdentifier("saved-voices-footnote")
                }.padding(.horizontal,24).padding(.top,16).padding(.bottom,18)
                    .frame(maxWidth:.infinity,minHeight:proxy.size.height,alignment:.topLeading)
            }
        }.background(CassiniTheme.windowGround)
            .navigationTitle(UXText.text("common.savedVoices"))
            .navigationBarBackButtonHidden(true)
            .accessibilityIdentifier(voices.loaded ? "saved-voices-ready":"saved-voices-loading")
            .task { await voices.refresh() }
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
            VStack(alignment:.leading,spacing:2) {
                Text(voice.name).font(.system(size:13,weight:.semibold))
                Text(UXText.text("savedVoices.row.meta",[
                    "meetingCount":UXText.text("savedVoices.row.meetingCount",["n":String(voices.meetingCounts[voice.id] ?? 0)]),
                    "confirmedSpeech":LibraryFormat.meetingDuration(Int64(voice.seconds*1000),locale:UXText.locale,language:UXText.language)]))
                    .font(.system(size:12)).foregroundStyle(CassiniTheme.ink2)
                if voice.stale {
                    Text(UXText.text("savedVoices.row.needsNaming"))
                        .font(.system(size:11,weight:.semibold)).foregroundStyle(CassiniTheme.warnInk)
                        .padding(.horizontal,7).padding(.vertical,2)
                        .background(CassiniTheme.warnTint,in:Capsule())
                        .padding(.top,3)
                        .accessibilityIdentifier("saved-voice-stale-" + voice.id)
                }
            }
            Spacer()
            HStack(spacing:12) {
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
            }.frame(height:30)
        }.padding(.horizontal,14).padding(.vertical,8).accessibilityElement(children:.contain)
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
