// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import CassiniLibrary

struct RecordingPageView: View {
    @State private var changingCapture = false
    @State private var explainingFallback = false
    let detail: MeetingDetailModel
    let format: LibraryFormat
    @State private var model: RecordingPageModel
    @State private var recorder = RecordingController.shared
    @FocusState private var titleFocused: Bool
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
                            if let started = (model.native ? recorder.startedAt : nil) ?? detail.meeting.start {
                                Text(UXText.text("recording.since",["time":format.rowTime(started)]))
                                    .font(.system(size:13)).foregroundStyle(LibraryTheme.dim)
                            }
                        }
                        Spacer(minLength:12)
                        Button { model.stop() } label: {
                            HStack(spacing:10) {
                                RoundedRectangle(cornerRadius:2).fill(.white).frame(width:12,height:12)
                                Text(UXText.text((model.saving || detail.meeting.state.lifecycle == .saving) ? "states.badge.saving" : "common.stop")).font(.system(size:16,weight:.bold))
                            }.padding(.horizontal,26).frame(height:48).foregroundStyle(.white).background(LibraryTheme.red,in:Capsule())
                        }.buttonStyle(.plain).disabled(model.saving || detail.meeting.state.lifecycle == .saving || (!model.canStop && !model.frozen))
                            .allowsHitTesting(!model.frozen).accessibilityIdentifier("recording-page-stop")
                    }
                }
                if let line = model.owned?.diskMinutes.map({ UXText.text("errors.diskLow.line",["n":String($0)]) }) ?? (model.native ? recorder.diskLine : nil) { Text(line).foregroundStyle(.orange).fixedSize(horizontal:false,vertical:true) }
                if let owned = model.owned, owned.input.failedSides.contains(.me) { CapturePermissionNotice(side:.me) }
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
                    Button(UXText.text("recording.changeWhatIsRecorded")) { changingCapture = true }.buttonStyle(.plain).font(.system(size:11.5,weight:.semibold))
                        .foregroundStyle(Color.accentColor).padding(.horizontal,16).frame(maxWidth:.infinity,minHeight:35,alignment:.leading).disabled(model.owned == nil && !model.frozen)
                        .accessibilityIdentifier("recording-change-sources")
                }.background(Color(nsColor:.textBackgroundColor),in:RoundedRectangle(cornerRadius:10))
                    .clipShape(RoundedRectangle(cornerRadius:10)).overlay { RoundedRectangle(cornerRadius:10).stroke(Color.secondary.opacity(0.25)) }
                if let owned = model.owned, owned.snapshot.others && !owned.snapshot.browserAlive,
                   owned.input.failedSides.contains(.others) || owned.snapshot.fallbackReason != nil {
                    HStack(alignment:.top,spacing:8) {
                        Text(UXText.text(owned.input.failedSides.contains(.others) ? "errors.othersPermission.line" : "errors.othersFallback.line")).fixedSize(horizontal:false,vertical:true)
                        if owned.input.failedSides.contains(.others) {
                            Button(UXText.text("errors.othersPermission.action")) { CaptureSettings.open(.others) }
                        } else { Button(UXText.text("errors.othersFallback.action")) { explainingFallback = true } }
                    }.font(.system(size:11.5)).foregroundStyle(LibraryTheme.dim).accessibilityIdentifier("recording-source-notice")
                }

            }.frame(maxWidth:640).padding(.top,32).padding(.horizontal,32).padding(.bottom,40).frame(maxWidth:.infinity)
        }.background(Color(nsColor:.textBackgroundColor))
            .accessibilityElement(children:.contain).accessibilityIdentifier("recording-page")
            .sheet(isPresented:$changingCapture) { WhatIsRecordedView(model:model) }
            .sheet(isPresented:$explainingFallback) {
                VStack(alignment:.leading,spacing:18) {
                    Text(UXText.text("errors.othersFallback.why.title")).font(.system(size:20,weight:.bold))
                    Text(UXText.text("errors.othersFallback.why.body")).foregroundStyle(LibraryTheme.dim).fixedSize(horizontal:false,vertical:true)
                    HStack { Spacer(); Button(UXText.text("common.close")) { explainingFallback = false }.keyboardShortcut(.defaultAction) }
                }.font(.system(size:13)).padding(26).frame(width:480).onExitCommand { explainingFallback = false }
            }
            .onAppear { model.update(detail.meeting) }
            .onChange(of:titleFocused) { _,focused in if !focused { model.flush() } }
            .onChange(of:detail.meeting.state.lifecycle) { _,_ in model.update(detail.meeting) }
            .onChange(of:detail.meeting.state.liveMs) { _,_ in model.update(detail.meeting) }
            .onChange(of:detail.meeting.audioTracks) { _,_ in model.update(detail.meeting) }
            .onDisappear { model.flush() }
    }
    private func caption(_ id: String) -> some View { Text(UXText.text(id)).font(.system(size:11.5,weight:.bold)).foregroundStyle(LibraryTheme.dim) }
    private func source(microphone: Bool) -> some View {
        let silent = microphone && model.microphoneSilent
        let enabled = microphone ? model.me : model.others
        let browser = model.owned?.snapshot.browserAlive ?? detail.meeting.isBrowserCapture
        let amber = LibraryTheme.amber
        return HStack(spacing:14) {
            Image(systemName:microphone ? "mic" : "macwindow").font(.system(size:16)).frame(width:20).foregroundStyle(silent ? amber : Color.primary).accessibilityHidden(true)
            VStack(alignment:.leading,spacing:2) {
                Text(UXText.text(microphone ? "common.yourMicrophone" : "common.theOthers")).fontWeight(.semibold)
                if !enabled { Text(UXText.text("whatIsRecorded.othersHeard.none.title")).font(.system(size:11.5)).foregroundStyle(LibraryTheme.dim) }
                else if silent {
                    Text(UXText.text("errors.micSilentRow.line")).font(.system(size:11.5,weight:.semibold)).foregroundStyle(amber).fixedSize(horizontal:false,vertical:true)
                } else if !microphone {
                    HStack(spacing:4) {
                        if browser { Image(systemName:"checkmark").accessibilityHidden(true) }
                        Text(UXText.text(browser ? (model.voiceCount > 0 ? "recording.others.browserVoices" : "common.listeningInsideBrowser") : "recordFirst.sound.title",["n":String(model.voiceCount)]))
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
