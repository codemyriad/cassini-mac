// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import CassiniLibrary

struct RecordingPageView: View {
    let detail: MeetingDetailModel
    let format: LibraryFormat
    @State private var model: RecordingPageModel
    @State private var recorder = RecordingController.shared
    @FocusState private var titleFocused: Bool
    @FocusState private var notesFocused: Bool
    init(detail: MeetingDetailModel, format: LibraryFormat) {
        self.detail = detail; self.format = format
        _model = State(initialValue: RecordingPageModel.editor(for: detail.meeting))
    }
    var body: some View {
        ScrollView {
            VStack(alignment:.leading,spacing:22) {
                TimelineView(.periodic(from:.now,by:1)) { _ in
                    HStack(spacing:22) {
                        Circle().fill(LibraryTheme.red).frame(width:22,height:22)
                            .overlay { Circle().stroke(LibraryTheme.red.opacity(0.12),lineWidth:8) }.accessibilityHidden(true)
                        VStack(alignment:.leading,spacing:2) {
                            Text(LibraryFormat.liveBig(model.elapsedMs)).font(.system(size:44,weight:.semibold)).monospacedDigit().tracking(-0.9)
                                .accessibilityIdentifier("recording-big-timer")
                            if let started = recorder.startedAt ?? detail.meeting.start {
                                Text(UXText.text("recording.since",["time":format.rowTime(started)]))
                                    .font(.system(size:13)).foregroundStyle(LibraryTheme.dim)
                            }
                        }
                        Spacer(minLength:12)
                        Button { if model.native { recorder.stop() } } label: {
                            HStack(spacing:10) {
                                RoundedRectangle(cornerRadius:2).fill(.white).frame(width:12,height:12)
                                Text(UXText.text(recorder.isSaving ? "states.badge.saving" : "common.stop")).font(.system(size:16,weight:.bold))
                            }.padding(.horizontal,26).frame(height:48).foregroundStyle(.white).background(LibraryTheme.red,in:Capsule())
                        }.buttonStyle(.plain).disabled(recorder.isSaving || (!model.native && !model.frozen))
                            .allowsHitTesting(!model.frozen).accessibilityIdentifier("recording-page-stop")
                    }
                }
                if let line = recorder.diskLine { Text(line).foregroundStyle(.orange).fixedSize(horizontal:false,vertical:true) }
                VStack(alignment:.leading,spacing:6) {
                    caption("recording.title.label")
                    TextField("",text:Binding(get:{ model.title },set:{ value in
                        model.title = value; model.changeTitle()
                    })).textFieldStyle(.plain).font(.system(size:16)).padding(.horizontal,12).frame(height:40)
                        .background(Color(nsColor:.textBackgroundColor),in:RoundedRectangle(cornerRadius:6))
                        .overlay { RoundedRectangle(cornerRadius:6).stroke(Color.secondary.opacity(0.25)) }
                        .focused($titleFocused).accessibilityLabel(UXText.text("recording.title.label")).accessibilityIdentifier("recording-title")
                        .disabled(detail.meeting.metadataReadOnly).allowsHitTesting(!model.frozen)
                    if detail.meeting.isBrowserCapture {
                        Text(UXText.text("recording.title.caption")).font(.system(size:11.5)).foregroundStyle(LibraryTheme.dim)
                    }
                }
                VStack(spacing:0) {
                    source(microphone:true)
                    Divider()
                    source(microphone:false)
                    Divider()
                    Button(UXText.text("recording.changeWhatIsRecorded")) {}.buttonStyle(.plain).font(.system(size:11.5,weight:.semibold))
                        .foregroundStyle(Color.accentColor).padding(.horizontal,16).frame(maxWidth:.infinity,minHeight:35,alignment:.leading).disabled(true)
                }.background(Color(nsColor:.textBackgroundColor),in:RoundedRectangle(cornerRadius:10))
                    .clipShape(RoundedRectangle(cornerRadius:10)).overlay { RoundedRectangle(cornerRadius:10).stroke(Color.secondary.opacity(0.25)) }
                VStack(alignment:.leading,spacing:6) {
                    caption("recording.notes.label")
                    TextEditor(text:Binding(get:{ model.notesText },set:{ value in
                        model.notesText = value; model.changeNotes()
                    })).font(.system(size:13)).monospacedDigit().scrollContentBackground(.hidden)
                        .padding(8).frame(height:80).background(Color(nsColor:.textBackgroundColor),in:RoundedRectangle(cornerRadius:6))
                        .overlay { RoundedRectangle(cornerRadius:6).stroke(Color.secondary.opacity(0.25)) }
                        .focused($notesFocused).accessibilityLabel(UXText.text("recording.notes.label")).accessibilityIdentifier("recording-notes")
                        .disabled(detail.meeting.metadataReadOnly).allowsHitTesting(!model.frozen)
                    Text(UXText.text("recording.notes.caption")).font(.system(size:11.5)).foregroundStyle(LibraryTheme.dim)
                }
            }.frame(maxWidth:640).padding(.top,32).padding(.horizontal,32).padding(.bottom,40).frame(maxWidth:.infinity)
        }.background(Color(nsColor:.textBackgroundColor))
            .accessibilityElement(children:.contain).accessibilityIdentifier("recording-page")
            .onAppear {
                model.update(detail.meeting)
                if RecordCoordinator.shared.focusNotesWhenOpened { notesFocused = true; RecordCoordinator.shared.focusNotesWhenOpened = false }
            }
            .onChange(of:RecordCoordinator.shared.focusNotesWhenOpened) { _,focus in
                if focus { notesFocused = true; RecordCoordinator.shared.focusNotesWhenOpened = false }
            }
            .onChange(of:notesFocused) { _,focused in if !focused { model.formatNotes(); model.flush() } }
            .onChange(of:titleFocused) { _,focused in if !focused { model.flush() } }
            .onChange(of:detail.meeting.state.liveMs) { _,_ in model.update(detail.meeting) }
            .onChange(of:detail.meeting.audioTracks) { _,_ in model.update(detail.meeting) }
            .onDisappear { model.flush() }
    }
    private func caption(_ id: String) -> some View { Text(UXText.text(id)).font(.system(size:11.5,weight:.bold)).foregroundStyle(LibraryTheme.dim) }
    private func source(microphone: Bool) -> some View {
        let silent = microphone && model.microphoneSilent
        let amber = LibraryTheme.amber
        return HStack(spacing:14) {
            Image(systemName:microphone ? "mic" : "macwindow").font(.system(size:16)).frame(width:20).foregroundStyle(silent ? amber : Color.primary).accessibilityHidden(true)
            VStack(alignment:.leading,spacing:2) {
                Text(UXText.text(microphone ? "common.yourMicrophone" : "common.theOthers")).fontWeight(.semibold)
                if silent {
                    Text(UXText.text("errors.micSilentRow.line")).font(.system(size:11.5,weight:.semibold)).foregroundStyle(amber).fixedSize(horizontal:false,vertical:true)
                } else if !microphone {
                    HStack(spacing:4) {
                        if detail.meeting.isBrowserCapture { Image(systemName:"checkmark").accessibilityHidden(true) }
                        Text(UXText.text(detail.meeting.isBrowserCapture ? "recording.others.browserVoices" : "recordFirst.sound.title",["n":String(model.voiceCount)]))
                    }.font(.system(size:11.5)).foregroundStyle(LibraryTheme.dim)
                }
            }.frame(maxWidth:.infinity,alignment:.leading)
            RecordingLevelMeter(level:microphone ? model.microphone : model.output, silent:silent,
                label:UXText.text(microphone ? "common.yourMicrophone" : "common.theOthers"))
                .frame(width:96,height:6).accessibilityIdentifier(microphone ? "recording-microphone-meter" : "recording-others-meter")
            if silent {
                Button(UXText.text("errors.micSilentRow.action")) {
                    if !model.frozen { NSWorkspace.shared.open(URL(fileURLWithPath:"/System/Library/PreferencePanes/Sound.prefPane")) }
                }.buttonStyle(.plain).font(.system(size:11.5,weight:.bold)).foregroundStyle(amber).frame(width:60,height:30)
                    .background(Color(nsColor:.controlBackgroundColor),in:RoundedRectangle(cornerRadius:6)).accessibilityIdentifier("recording-check-microphone")
                    .allowsHitTesting(!model.frozen)
            } else { Color.clear.frame(width:60,height:30).accessibilityHidden(true) }
        }.padding(.horizontal,16).frame(minHeight:56).padding(.vertical,0)
            .background(silent ? LibraryTheme.amberTint : Color.clear)
            .accessibilityElement(children:.contain)
    }
}

struct RecordingLevelMeter: View {
    let level: Float
    var silent = false
    let label: String
    var body: some View {
        GeometryReader { geometry in
            Capsule().fill(silent ? LibraryTheme.amber.opacity(0.2) : Color.secondary.opacity(0.18))
                .overlay(alignment:.leading) { Capsule().fill(silent ? Color.orange : Color.primary).frame(width:geometry.size.width * Double(max(0,min(1,level)))) }
        }.accessibilityRepresentation { ProgressView(value:Double(max(0,min(1,level)))).accessibilityLabel(label) }
    }
}
