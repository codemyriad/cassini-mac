// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import CassiniSpectrogram
import CassiniLibrary

struct RecordingPageView: View {
    @State private var changingCapture = false
    @State private var sourceProblem = false
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
                VStack(alignment:.leading,spacing:6) {
                    TextField(UXText.text("recording.title.label"),text:Binding(get:{ model.title },set:{ value in
                        model.title = value; model.changeTitle()
                    })).textFieldStyle(.plain).font(.system(size:24,weight:.bold))
                        .focused($titleFocused).accessibilityLabel(UXText.text("recording.title.label"))
                        .accessibilityIdentifier("recording-title")
                        .disabled(detail.meeting.metadataReadOnly).allowsHitTesting(!model.frozen)
                    Text(format.previewSubtitle(detail.meeting.meetingTime,durationMs:nil))
                        .font(.system(size:13)).foregroundStyle(CassiniTheme.ink2)
                        .accessibilityIdentifier("recording-date")
                }
                TimelineView(.periodic(from:.now,by:1)) { _ in
                    HStack(spacing:12) {
                        Circle().fill(CassiniTheme.recordInk).frame(width:8,height:8).accessibilityHidden(true)
                        Text(LibraryFormat.liveBig(model.elapsedMs))
                            .font(.system(size:RecordingPaneMetrics.timerSize,weight:.semibold)).monospacedDigit()
                            .accessibilityIdentifier("recording-big-timer")
                        Spacer(minLength:8)
                        Button { model.stop() } label: {
                            HStack(spacing:6) {
                                RoundedRectangle(cornerRadius:1.5).fill(CassiniTheme.onRecord).frame(width:8,height:8)
                                    .accessibilityHidden(true)
                                Text(UXText.text((model.saving || detail.meeting.state.lifecycle == .saving) ? "states.badge.saving" : "common.stop"))
                                    .font(.system(size:12,weight:.semibold))
                            }.padding(.horizontal,14).frame(height:RecordingPaneMetrics.stopHeight)
                                .foregroundStyle(CassiniTheme.onRecord).background(CassiniTheme.record,in:Capsule())
                        }.buttonStyle(.plain).disabled(model.saving || detail.meeting.state.lifecycle == .saving || (!model.canStop && !model.frozen))
                            .allowsHitTesting(!model.frozen).accessibilityIdentifier("recording-page-stop")
                    }
                }
                if let line = model.owned?.diskMinutes.map({ UXText.text("errors.diskLow.line",["n":String($0)]) }) ?? (model.native ? recorder.diskLine : nil) { Text(line).foregroundStyle(CassiniTheme.warningNotice).fixedSize(horizontal:false,vertical:true) }
                if let owned = model.owned, owned.input.failedSides.contains(.me) { CapturePermissionNotice(side:.me,refusal:owned.input.refusedSides[.me]) }
                if sourceProblem {
                    Text(UXText.text("recording.sourceProblem")).foregroundStyle(CassiniTheme.warningNotice).fixedSize(horizontal:false,vertical:true)
                        .accessibilityIdentifier("recording-source-problem")
                }
                VStack(spacing:0) {
                    source(microphone:true)
                    Divider()
                    source(microphone:false)
                    Divider()
                    Button(UXText.text("recording.changeWhatIsRecorded")) { changingCapture = true }.buttonStyle(.plain).font(.system(size:11.5,weight:.semibold))
                        .foregroundStyle(CassiniTheme.accentInk).padding(.horizontal,16).frame(maxWidth:.infinity,minHeight:35,alignment:.leading).disabled(model.owned == nil && !model.frozen)
                        .accessibilityIdentifier("recording-change-sources")
                    Divider()
                    Button(UXText.text("details.link")) { RecordingDetailsCoordinator.shared.show(detail.meeting) }.buttonStyle(.plain).font(.system(size:11.5,weight:.semibold))
                        .foregroundStyle(CassiniTheme.accentInk).padding(.horizontal,16).frame(maxWidth:.infinity,minHeight:35,alignment:.leading)
                        .accessibilityIdentifier("recording-details-link")
                }.background(CassiniTheme.surface,in:RoundedRectangle(cornerRadius:10))
                    .clipShape(RoundedRectangle(cornerRadius:10)).overlay { RoundedRectangle(cornerRadius:10).stroke(CassiniTheme.cardStroke) }
                if let owned = model.owned, owned.snapshot.others && !owned.snapshot.browserAlive,
                   owned.input.failedSides.contains(.others) || owned.snapshot.fallbackReason != nil {
                    HStack(alignment:.top,spacing:8) {
                        // D58.1: the permission line and its settings action only for a denial.
                        let failed = owned.input.failedSides.contains(.others), denied = failed && owned.input.othersDenied
                        Text(UXText.text(!failed ? "errors.othersFallback.line" : denied ? "errors.othersPermission.line" : "errors.deviceUnavailable.others")).fixedSize(horizontal:false,vertical:true)
                        if denied {
                            Button(UXText.text("errors.othersPermission.action")) { CaptureSettings.open(.others) }
                        } else if !failed { Button(UXText.text("errors.othersFallback.action")) { explainingFallback = true } }
                    }.font(.system(size:11.5)).foregroundStyle(CassiniTheme.ink2).accessibilityIdentifier("recording-source-notice")
                }

            }.frame(maxWidth:640).padding(.top,28).padding(.horizontal,24).padding(.bottom,40).frame(maxWidth:.infinity)
        }.background(CassiniTheme.paneGround)
            .accessibilityElement(children:.contain).accessibilityIdentifier("recording-page")
            .sheet(isPresented:$changingCapture) { WhatIsRecordedView(model:model) }
            .sheet(isPresented:$explainingFallback) {
                VStack(alignment:.leading,spacing:18) {
                    Text(UXText.text("errors.othersFallback.why.title")).font(.system(size:20,weight:.bold))
                    Text(UXText.text("errors.othersFallback.why.body")).foregroundStyle(CassiniTheme.ink2).fixedSize(horizontal:false,vertical:true)
                    HStack { Spacer(); Button(UXText.text("common.close")) { explainingFallback = false }.keyboardShortcut(.defaultAction) }
                }.font(.system(size:13)).padding(26).frame(width:480).onExitCommand { explainingFallback = false }
            }
            .onAppear { model.update(detail.meeting) }
            // D52: the live source line comes from session.json only (GNOME live_problem).
            .task(id:"\(detail.meeting.libraryKey)#\(LibraryStore.shared.revision)") {
                let folder = detail.meeting.folder
                let problem = await Task.detached {
                    RecordingDetailsReport.liveSourceProblem(session:RecordingDetailsReport.Inputs.load(folder:folder,lifecycle:.recording,title:"",transcriptDone:false).session)
                }.value
                if !Task.isCancelled { sourceProblem = problem }
            }
            .onChange(of:titleFocused) { _,focused in if !focused { model.flush() } }
            .onChange(of:detail.meeting.state.lifecycle) { _,_ in model.update(detail.meeting) }
            .onChange(of:detail.meeting.state.liveMs) { _,_ in model.update(detail.meeting) }
            .onChange(of:detail.meeting.audioTracks) { _,_ in model.update(detail.meeting) }
            .onDisappear { model.flush() }
    }
    private func source(microphone: Bool) -> some View {
        let silent = microphone && model.microphoneSilent
        let enabled = microphone ? model.me : model.others
        let browser = model.owned?.snapshot.browserAlive ?? detail.meeting.isBrowserCapture
        let amber = CassiniTheme.warnInk
        return HStack(spacing:14) {
            Image(systemName:microphone ? "mic" : "macwindow").font(.system(size:16)).frame(width:20).foregroundStyle(silent ? amber : CassiniTheme.primaryInk).accessibilityHidden(true)
            VStack(alignment:.leading,spacing:2) {
                Text(UXText.text(microphone ? "common.yourMicrophone" : "common.theOthers")).fontWeight(.semibold)
                if !enabled { Text(UXText.text("whatIsRecorded.othersHeard.none.title")).font(.system(size:11.5)).foregroundStyle(CassiniTheme.ink2) }
                else if silent {
                    Text(UXText.text("errors.micSilentRow.line")).font(.system(size:11.5,weight:.semibold)).foregroundStyle(amber).fixedSize(horizontal:false,vertical:true)
                } else if !microphone {
                    HStack(spacing:4) {
                        if browser { Image(systemName:"checkmark").accessibilityHidden(true) }
                        Text(UXText.text(browser ? (model.voiceCount > 0 ? "recording.others.browserVoices" : "common.listeningInsideBrowser") : "recordFirst.sound.title",["n":String(model.voiceCount)]))
                    }.font(.system(size:11.5)).foregroundStyle(CassiniTheme.ink2)
                }
            }.frame(maxWidth:.infinity,alignment:.leading).layoutPriority(1)
            RecordingSpectrogramStrip(controller:model.spectrogram,lane:microphone ? .me : .others,silent:model.microphoneSilent)
                .frame(minWidth:32,idealWidth:96,maxWidth:96).frame(height:32)
                .accessibilityRepresentation {
                    ProgressView(value:Double(max(0,min(1,microphone ? model.microphone : model.output))))
                        .accessibilityLabel(UXText.text(microphone ? "common.yourMicrophone" : "common.theOthers"))
                }.accessibilityIdentifier(microphone ? "recording-microphone-meter" : "recording-others-meter")
            if silent {
                Button(UXText.text("errors.micSilentRow.action")) {
                    if !model.frozen { NSWorkspace.shared.open(URL(string:"x-apple.systempreferences:com.apple.Sound-Settings.extension?input")!) }
                }.buttonStyle(.plain).font(.system(size:11.5,weight:.bold)).foregroundStyle(amber).frame(width:58,height:30)
                    .background(CassiniTheme.controlFill,in:RoundedRectangle(cornerRadius:6)).accessibilityIdentifier("recording-check-microphone")
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
