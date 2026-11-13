// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import CassiniSpectrogram
import CassiniLibrary

struct RecordingPageView: View {
    @State private var changingCapture = false
    @State private var renaming = false
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
                heading
                timerRow
                if let line = model.owned?.diskMinutes.map({ UXText.text("errors.diskLow.line",["n":String($0)]) }) ?? (model.native ? recorder.diskLine : nil) { Text(line).foregroundStyle(CassiniTheme.warningNotice).fixedSize(horizontal:false,vertical:true) }
                if let owned = model.owned, owned.input.failedSides.contains(.me) { CapturePermissionNotice(side:.me,refusal:owned.input.refusedSides[.me]) }
                if sourceProblem {
                    Text(UXText.text("recording.sourceProblem")).foregroundStyle(CassiniTheme.warningNotice).fixedSize(horizontal:false,vertical:true)
                        .accessibilityIdentifier("recording-source-problem")
                }
                sourcesCard
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

            }.padding(.horizontal,44).padding(.bottom,40).frame(maxWidth:.infinity,alignment:.leading)
        }.foregroundStyle(CassiniTheme.ink).background(CassiniTheme.surface)
            .accessibilityElement(children:.contain).accessibilityIdentifier("recording-page")
            .sheet(isPresented:$changingCapture) { WhatIsRecordedView(model:model) }
            .sheet(isPresented:$explainingFallback) {
                VStack(alignment:.leading,spacing:18) {
                    Text(UXText.text("errors.othersFallback.why.title")).font(.system(size:20,weight:.bold))
                    Text(UXText.text("errors.othersFallback.why.body")).foregroundStyle(CassiniTheme.ink2).fixedSize(horizontal:false,vertical:true)
                    HStack { Spacer(); Button(UXText.text("common.close")) { explainingFallback = false }.keyboardShortcut(.defaultAction) }
                }.font(.system(size:13)).padding(26).frame(width:480).onExitCommand { explainingFallback = false }
            }
            .onAppear { model.didPresent(); model.update(detail.meeting) }
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
    private var heading: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(model.displayTitle).font(.system(size: 22, weight: .bold))
                    .textSelection(.enabled).accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("recording-page-title")
                Button { renaming = true } label: { Image(systemName: "pencil").frame(width: 26, height: 26) }
                    .buttonStyle(.borderless).foregroundStyle(CassiniTheme.ink2)
                    .disabled(detail.meeting.metadataReadOnly || model.saving || model.frozen)
                    .accessibilityLabel(UXText.text("meeting.renameEllipsis"))
                    .accessibilityIdentifier("recording-rename")
                    .popover(isPresented: $renaming) { titleEditor }
            }
            Text(recordingDate).foregroundStyle(CassiniTheme.ink2)
                .accessibilityIdentifier("recording-date")
        }.frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 8).padding(.bottom, 18)
            .overlay(alignment: .bottom) { Rectangle().fill(CassiniTheme.lineSoft).frame(height: 1) }
            .accessibilityElement(children: .contain).accessibilityIdentifier("recording-heading")
    }
    private var timerRow: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            HStack(spacing: 16) {
                HStack(spacing: 12) {
                    Circle().fill(CassiniTheme.recordInk).frame(width: 14, height: 14)
                        .overlay { Circle().stroke(CassiniTheme.recordInk.opacity(0.12), lineWidth: 5) }
                        .accessibilityHidden(true)
                    Text(LibraryFormat.liveBig(model.elapsedMs)).font(.system(size: 30, weight: .semibold))
                        .monospacedDigit().tracking(-0.5).accessibilityIdentifier("recording-big-timer")
                }
                Button { model.flush(); model.stop() } label: {
                    HStack(spacing: 7) {
                        RoundedRectangle(cornerRadius: 2).fill(CassiniTheme.onRecord).frame(width: 9, height: 9)
                        Text(UXText.text((model.saving || detail.meeting.state.lifecycle == .saving) ? "states.badge.saving" : "common.stop"))
                            .font(.system(size: 13, weight: .semibold))
                    }.padding(.horizontal, 14).frame(height: 30)
                        .foregroundStyle(CassiniTheme.onRecord).background(CassiniTheme.record, in: Capsule())
                }.buttonStyle(.plain)
                    .disabled(model.saving || detail.meeting.state.lifecycle == .saving || (!model.canStop && !model.frozen))
                    .allowsHitTesting(!model.frozen).accessibilityIdentifier("recording-page-stop")
                Spacer(minLength: 0)
            }.padding(.top, 2)
        }
    }
    private var sourcesCard: some View {
        VStack(spacing:0) {
            source(microphone:true)
            Divider()
            source(microphone:false)
            Divider()
            Button { changingCapture = true } label: {
                HStack(spacing: 7) {
                    Image(systemName: "mic").foregroundStyle(CassiniTheme.ink2).accessibilityHidden(true)
                    Text(UXText.text("recording.changeWhatIsRecorded"))
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").foregroundStyle(CassiniTheme.ink3).accessibilityHidden(true)
                }.padding(.horizontal, 14).frame(minHeight: 38)
            }.buttonStyle(.plain).font(.system(size: 13, weight: .medium))
                .foregroundStyle(CassiniTheme.ink).disabled(model.owned == nil && !model.frozen)
                .accessibilityIdentifier("recording-change-sources")
        }.background(CassiniTheme.surface, in: RoundedRectangle(cornerRadius: 12))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay { RoundedRectangle(cornerRadius: 12).stroke(CassiniTheme.cardStroke) }
            .accessibilityElement(children: .contain).accessibilityIdentifier("recording-sources")
    }
    private var recordingDate: String {
        if model.native, let started = recorder.startedAt { return format.previewSubtitle(started, durationMs: nil) }
        return format.previewSubtitle(detail.meeting.meetingTime, durationMs: nil)
    }
    private var titleEditor: some View {
        VStack(alignment: .leading, spacing: 14) {
            TextField(UXText.text("recording.title.label"), text: Binding(get: { model.title }, set: {
                model.title = $0; model.changeTitle()
            })).textFieldStyle(.roundedBorder).focused($titleFocused)
                .accessibilityIdentifier("recording-title")
                .onSubmit { model.flush(); renaming = false }
            if detail.meeting.isBrowserCapture {
                Text(UXText.text("recording.title.caption")).font(.system(size: 11.5)).foregroundStyle(CassiniTheme.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack { Spacer(); Button(UXText.text("common.done")) { model.flush(); renaming = false }.keyboardShortcut(.defaultAction) }
        }.padding(18).frame(width: 320)
            .onAppear { titleFocused = true }
            .onDisappear { model.flush() }
            .onExitCommand { model.flush(); renaming = false }
    }
    private func source(microphone: Bool) -> some View {
        let silent = microphone && model.microphoneSilent
        let enabled = microphone ? model.me : model.others
        let browser = model.owned?.snapshot.browserAlive ?? detail.meeting.isBrowserCapture
        let amber = CassiniTheme.warnInk
        return HStack(spacing:14) {
            VStack(alignment:.leading,spacing:2) {
                Text(UXText.text(microphone ? "common.yourMicrophone" : "common.theOthers")).fontWeight(.semibold).foregroundStyle(silent ? amber : CassiniTheme.ink)
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
                .frame(width:200,height:32)
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
            } else { Color.clear.frame(width:58,height:30).accessibilityHidden(true) }
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
