// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import CassiniSpectrogram
import CassiniLibrary

struct RecordingPageView: View {
    @State private var changingCapture = false
    @State private var sourceProblem = false
    @State private var explainingFallback = false
    let meeting: LibraryMeeting
    let format: LibraryFormat
    @State private var model: RecordingPageModel
    @State private var recorder = RecordingController.shared
    @FocusState private var titleFocused: Bool
    init(meeting: LibraryMeeting, format: LibraryFormat) {
        self.meeting = meeting; self.format = format
        _model = State(initialValue: RecordingPageModel.editor(for: meeting))
    }
    var body: some View {
        ScrollView {
            VStack(alignment:.leading,spacing:22) {
                VStack(alignment:.leading,spacing:6) {
                    TextField(UXText.text("recording.title.label"),text:Binding(get:{ model.title },set:{ value in
                        model.title = value; model.changeTitle()
                    })).textFieldStyle(.plain).font(.system(size:24,weight:.bold))
                        .focused($titleFocused).accessibilityLabel(UXText.text("recording.title.label"))
                        .accessibilityIdentifier("recording-title")
                        .disabled(meeting.metadataReadOnly).allowsHitTesting(!model.frozen)
                    Text(format.previewSubtitle(meeting.meetingTime,durationMs:nil))
                        .font(.system(size:13)).foregroundStyle(CassiniTheme.ink2)
                        .accessibilityIdentifier("recording-date")
                }
                TimelineView(.periodic(from:.now,by:1)) { _ in
                    HStack(spacing:16) {
                        Circle().fill(CassiniTheme.recordInk).frame(width:8,height:8)
                            .padding(4).background(CassiniTheme.recordTint,in:Circle()).accessibilityHidden(true)
                        Text(LibraryFormat.liveBig(model.elapsedMs))
                            .font(.system(size:RecordingPaneMetrics.timerSize,weight:.semibold)).monospacedDigit()
                            .accessibilityIdentifier("recording-big-timer")
                        Button { model.stop() } label: {
                            HStack(spacing:6) {
                                RoundedRectangle(cornerRadius:1.5).fill(CassiniTheme.onRecord).frame(width:8,height:8)
                                    .accessibilityHidden(true)
                                Text(UXText.text((model.saving || meeting.state.lifecycle == .saving) ? "states.badge.saving" : "common.stop"))
                                    .font(.system(size:12,weight:.semibold))
                            }.padding(.horizontal,14).frame(height:RecordingPaneMetrics.stopHeight)
                                .foregroundStyle(CassiniTheme.onRecord).background(CassiniTheme.record,in:Capsule())
                        }.buttonStyle(.plain).disabled(model.saving || meeting.state.lifecycle == .saving || (!model.canStop && !model.frozen))
                            .allowsHitTesting(!model.frozen).accessibilityIdentifier("recording-page-stop")
                    }
                }
                if let line = model.owned?.diskMinutes.map({ UXText.text("errors.diskLow.line",["n":String($0)]) }) ?? (model.native ? recorder.diskLine : nil) { Text(line).foregroundStyle(CassiniTheme.warningNotice).fixedSize(horizontal:false,vertical:true) }
                if let owned = model.owned, owned.presentation.failedSides.contains(.me) { CapturePermissionNotice(side:.me,refusal:owned.presentation.refusedSides[.me]) }
                if sourceProblem {
                    Text(UXText.text("recording.sourceProblem")).foregroundStyle(CassiniTheme.warningNotice).fixedSize(horizontal:false,vertical:true)
                        .accessibilityIdentifier("recording-source-problem")
                }
                VStack(spacing:0) {
                    RecordingSourceRow(model:model,microphone:true)
                    Rectangle().fill(CassiniTheme.lineSoft).frame(height:1)
                    RecordingSourceRow(model:model,microphone:false)
                    Rectangle().fill(CassiniTheme.lineSoft).frame(height:1)
                    Button { changingCapture = true } label: {
                        HStack(spacing:8) {
                            Image(systemName:"mic").accessibilityHidden(true)
                            Text(UXText.text("recording.changeWhatIsRecorded"))
                            Spacer()
                            Image(systemName:"chevron.right").accessibilityHidden(true)
                        }.padding(.horizontal,16).frame(maxWidth:.infinity,minHeight:40,alignment:.leading).contentShape(Rectangle())
                    }.buttonStyle(.plain).font(.system(size:13)).foregroundStyle(CassiniTheme.ink)
                        .disabled(model.owned == nil && !model.frozen).accessibilityIdentifier("recording-change-sources")
                }.background(CassiniTheme.surface,in:RoundedRectangle(cornerRadius:10))
                    .clipShape(RoundedRectangle(cornerRadius:10)).overlay { RoundedRectangle(cornerRadius:10).stroke(CassiniTheme.cardStroke) }
                if let owned = model.owned, owned.presentation.others && !owned.presentation.browserAlive,
                   owned.presentation.failedSides.contains(.others) || owned.presentation.fallbackReason != nil {
                    HStack(alignment:.top,spacing:8) {
                        // D58.1: the permission line and its settings action only for a denial.
                        let failed = owned.presentation.failedSides.contains(.others), denied = failed && owned.presentation.othersDenied
                        Text(UXText.text(!failed ? "errors.othersFallback.line" : denied ? "errors.othersPermission.line" : "errors.deviceUnavailable.others")).fixedSize(horizontal:false,vertical:true)
                        if denied {
                            Button(UXText.text("errors.othersPermission.action")) { CaptureSettings.open(.others) }
                        } else if !failed { Button(UXText.text("errors.othersFallback.action")) { explainingFallback = true } }
                    }.font(.system(size:11.5)).foregroundStyle(CassiniTheme.ink2).accessibilityIdentifier("recording-source-notice")
                }

            }.frame(maxWidth:640).padding(.top,28).padding(.horizontal,24).padding(.bottom,40).frame(maxWidth:.infinity)
        }.cassiniTopScrollEdge()
            .background(CassiniTheme.paneGround)
            .accessibilityElement(children:.contain).accessibilityIdentifier("recording-page")
            .sheet(isPresented:$changingCapture) { WhatIsRecordedView(model:model) }
            .sheet(isPresented:$explainingFallback) {
                VStack(alignment:.leading,spacing:18) {
                    Text(UXText.text("errors.othersFallback.why.title")).font(.system(size:20,weight:.bold))
                    Text(UXText.text("errors.othersFallback.why.body")).foregroundStyle(CassiniTheme.ink2).fixedSize(horizontal:false,vertical:true)
                    HStack { Spacer(); Button(UXText.text("common.close")) { explainingFallback = false }.keyboardShortcut(.defaultAction) }
                }.font(.system(size:13)).padding(26).frame(width:480).onExitCommand { explainingFallback = false }
            }
            .onAppear { model.update(meeting,isEditing:titleFocused) }
            // D52: the live source line comes from session.json only (GNOME live_problem).
            .task(id:"\(meeting.libraryKey)#\(LibraryStore.shared.revision)") {
                let folder = meeting.folder
                let problem = await Task.detached {
                    RecordingDetailsReport.liveSourceProblem(session:RecordingDetailsReport.Inputs.load(folder:folder,lifecycle:.recording,title:"",transcriptDone:false).session)
                }.value
                if !Task.isCancelled { sourceProblem = problem }
            }
            .onChange(of:titleFocused) { _,focused in if !focused { model.flush(); model.update(meeting) } }
            .onChange(of:meeting.title) { _,_ in model.update(meeting,isEditing:titleFocused) }
            .onChange(of:meeting.state.lifecycle) { _,_ in model.update(meeting,isEditing:titleFocused) }
            .onChange(of:meeting.state.liveMs) { _,_ in model.update(meeting,isEditing:titleFocused) }
            .onChange(of:meeting.audioTracks) { _,_ in model.update(meeting,isEditing:titleFocused) }
            .onDisappear { model.flush() }
    }
}

private struct RecordingSourceRow: View {
    let model: RecordingPageModel
    let microphone: Bool
    var body: some View {
        let silent = microphone && model.microphoneSilent
        let enabled = microphone ? model.me : model.others
        let browser = model.owned?.presentation.browserAlive ?? model.meeting.isBrowserCapture
        let amber = CassiniTheme.warnInk
        return HStack(spacing:14) {
            VStack(alignment:.leading,spacing:2) {
                Text(UXText.text(microphone ? "common.yourMicrophone" : "common.theOthers")).fontWeight(.semibold).foregroundStyle(silent ? amber : CassiniTheme.primaryInk)
                if !enabled { Text(UXText.text("whatIsRecorded.othersHeard.none.title")).font(.system(size:11.5)).foregroundStyle(CassiniTheme.ink2) }
                else if silent {
                    Text(UXText.text("errors.micSilentRow.line")).font(.system(size:11.5,weight:.semibold)).foregroundStyle(amber).fixedSize(horizontal:false,vertical:true)
                } else if !microphone {
                    HStack(spacing:4) {
                        if browser { Image(systemName:"checkmark").accessibilityHidden(true) }
                        Text(UXText.text(browser ? (model.voiceCount > 0 ? "recording.others.browserVoices" : "common.listeningInsideBrowser") : "recordFirst.sound.title",["n":String(model.voiceCount)]))
                    }.font(.system(size:11.5)).foregroundStyle(CassiniTheme.ink2)
                }
            }.frame(maxWidth:.infinity,alignment:.leading)
            RecordingSpectrogramStrip(controller:model.spectrogram,lane:microphone ? .me : .others,silent:model.microphoneSilent)
                .frame(width:96,height:32)
                .accessibilityRepresentation {
                    ProgressView(value:Double(max(0,min(1,microphone ? model.microphone : model.output))))
                        .accessibilityLabel(UXText.text(microphone ? "common.yourMicrophone" : "common.theOthers"))
                }.accessibilityIdentifier(microphone ? "recording-microphone-meter" : "recording-others-meter")
            if silent {
                Button(UXText.text("errors.micSilentRow.action")) {
                    if !model.frozen { NSWorkspace.shared.open(URL(string:"x-apple.systempreferences:com.apple.Sound-Settings.extension?input")!) }
                }.buttonStyle(.plain).font(.system(size:11.5,weight:.bold)).foregroundStyle(amber).frame(width:58,height:30)
                    .background(CassiniTheme.controlFill,in:RoundedRectangle(cornerRadius:6))
                    .overlay { RoundedRectangle(cornerRadius:6).stroke(CassiniTheme.cardStroke,lineWidth:1) }.accessibilityIdentifier("recording-check-microphone")
                    .allowsHitTesting(!model.frozen)
            }
        }.padding(.horizontal,16).padding(.vertical,12).frame(minHeight:62)
            .background(silent ? CassiniTheme.warnTint : Color.clear)
            .accessibilityElement(children:.contain)
    }
}

struct RecordingLevelMeter: View {
    let level: Float
    var silent = false
    let label: String
    var body: some View {
        GeometryReader { geometry in
            Capsule().fill(silent ? CassiniTheme.warnInk.opacity(0.2) : CassiniTheme.secondaryColor.opacity(0.18))
                .overlay(alignment:.leading) { Capsule().fill(silent ? CassiniTheme.warningNotice : CassiniTheme.primaryInk).frame(width:geometry.size.width * Double(max(0,min(1,level)))) }
        }.accessibilityRepresentation { ProgressView(value:Double(max(0,min(1,level)))).accessibilityLabel(label) }
    }
}

// L-47 drawn Mac values; keep the compact controls adjustable in one place.
private enum RecordingPaneMetrics {
    static let timerSize: CGFloat = 30
    static let stopHeight: CGFloat = 30
}
