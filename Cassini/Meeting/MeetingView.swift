// SPDX-License-Identifier: GPL-3.0-or-later
import CassiniLibrary
import SwiftUI

struct MeetingView: View {
    @Bindable var model: MeetingDetailModel
    let format: LibraryFormat
    @AppStorage("CassiniCompanionSuggestionDismissed") private var suggestionDismissed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var showsCompanionSuggestion: Bool { !suggestionDismissed && !CaptureCollection.shared.connected }
    private var meeting: LibraryMeeting { model.meeting }
    private var shares: [String: Int] { model.shares }
    /// M11: paragraphs only; an aside is shown inside its host.
    private var visibleTurns: [MeetingPresentation.Turn] { MeetingPresentation.visibleTurns(model.turns) }
    private func name(_ speaker: String) -> String { model.speakerName(speaker) }
    private func asides(_ turn: MeetingPresentation.Turn) -> [MeetingTranscriptText.Aside] {
        turn.asides.compactMap { aside in
            model.turns.indices.contains(aside.turn) ? .init(after:aside.after,name:name(model.turns[aside.turn].speaker),items:model.turns[aside.turn].items) : nil
        }
    }
    /// D55.1 meeting.turn.over: the other speakers whose words overlap this turn.
    private func over(_ turn: MeetingPresentation.Turn) -> String? {
        turn.over.isEmpty ? nil : UXText.text("meeting.turn.over",["names":turn.over.map(name).joined(separator:", ")])
    }
    /// The turn's words in reading order with each aside's text where its chip sits.
    private func spoken(_ turn: MeetingPresentation.Turn) -> String {
        let chips = asides(turn)
        var parts: [String] = []
        for (index,item) in turn.items.enumerated() {
            parts.append(item.text)
            for chip in chips where chip.after == index { parts.append(chip.label) }
        }
        return parts.joined(separator:" ")
    }
    private var currentTurn: Int? {
        visibleTurns.last { turn in
            (turn.items + asides(turn).flatMap(\.items)).contains { $0.startMs <= model.positionMs && model.positionMs < $0.endMs }
        }?.id
    }
    private func colour(_ index: Int) -> Color {
        [Color.accentColor, Color(red: 179/255, green: 71/255, blue: 0), Color(red: 125/255, green: 60/255, blue: 152/255)][index % 3]
    }
    private func turnLabel(_ turn: MeetingPresentation.Turn) -> String {
        var parts: [String] = [name(turn.speaker), LibraryFormat.position(turn.startMs)]
        if let over = over(turn) { parts.append(over) }
        parts.append(spoken(turn))
        return parts.joined(separator:", ")
    }
    /// One transcript turn. Its own function so Xcode 16.4 can type-check `body`.
    private func turnRow(_ turn: MeetingPresentation.Turn) -> some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 5) {
                    Text(name(turn.speaker))
                        .fontWeight(.semibold).foregroundStyle(colour(meeting.speaker(for:turn.speaker)?.colourIndex ?? 0))
                    if meeting.speaker(for:turn.speaker)?.provenance == .recognised { autoTag }
                }.fixedSize()
                Text(LibraryFormat.position(turn.startMs)).font(.system(size: 11.5)).foregroundStyle(.secondary).monospacedDigit()
                if let over = over(turn) {
                    Text(over).font(.system(size: 11.5)).foregroundStyle(.secondary)
                        .help(UXText.text("meeting.turn.over.tooltip"))
                }
            }.frame(width: 120, alignment: .leading)
            MeetingTranscriptText(items:turn.items,asides:asides(turn),positionMs:model.positionMs,seek:model.seek)
                .frame(maxWidth:.infinity,alignment:.leading)
        }.id(turn.id)
            .accessibilityElement(children:.ignore)
            .accessibilityLabel(turnLabel(turn))
            .accessibilityHint(turn.over.isEmpty ? "" : UXText.text("meeting.turn.over.tooltip"))
            .accessibilityIdentifier("meeting-turn-" + String(turn.id))
            .accessibilityAction(named:Text(UXText.text("player.playFromHere"))) { model.playFrom(Int(turn.startMs)) }
    }
    /// The speakers column, kept out of `body` for the Xcode 16.4 type checker.
    private var speakersPane: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(UXText.text("common.speakers")).font(.system(size: 11.5, weight: .bold)).foregroundStyle(.secondary)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(meeting.speakers, id: \.id) { speaker in speakerRow(speaker).id(speaker.id) }
                    }
                }.onChange(of: model.listen.speaker) { _, speaker in
                    if let speaker = speaker.flatMap({ meeting.speaker(for:$0) }) {
                        if reduceMotion { proxy.scrollTo(speaker.id,anchor:.center) }
                        else { withAnimation { proxy.scrollTo(speaker.id,anchor:.center) } }
                    }
                }
            }
            Spacer(minLength: 0)
        }.padding(.horizontal, 19).padding(.top, 14)
            .frame(width: 260).frame(maxHeight: .infinity)
            .background(LibraryTheme.sidebar)
            .accessibilityElement(children: .contain).accessibilityLabel(UXText.text("meeting.speakersPane.a11y"))
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                speakersPane
                Divider()
                ScrollViewReader { proxy in ScrollView {
                    LazyVStack(alignment: .leading, spacing: 22) {
                        if meeting.hasNoSpeech {
                            // A Library move disables Write down again only (the line disables it); the
                            // permission hint's Open System Settings stays available, as in Recording details.
                            NoSpeechTranscriptLine(action:meeting.canWriteDown ? { TranscriptionQueue.shared.writeDown(model) } : nil,meeting:meeting)
                        }
                        if let line = issueLine { InlineMeetingLine(id: line, actionID: meeting.state.transcript == .failed ? "common.tryAgain" : nil, action: meeting.state.transcript == .failed ? { TranscriptionQueue.shared.writeDown(model) } : nil).disabled(LibraryMoveCoordinator.shared.busy) }
                        if showsCompanionSuggestion { companionCard }
                        ForEach(visibleTurns) { turn in turnRow(turn) }
                    }.padding(.horizontal, 48).padding(.vertical, 22)
                }.accessibilityIdentifier("meeting-transcript")
                    .task {
                        await Task.yield()
                        if let turn = currentTurn { proxy.scrollTo(turn,anchor:.center) }
                    }
                    .onChange(of: currentTurn) { _, turn in
                        if let turn {
                            if reduceMotion { proxy.scrollTo(turn,anchor:.center) }
                            else { withAnimation { proxy.scrollTo(turn,anchor:.center) } }
                        }
                    }
                }
            }
            // Keep the controls in the main layout/hit-test tree. On macOS 15,
            // safeAreaInset paints this bar but its buttons fail AX hit testing.
            if let presentation = model.listeningPresentation {
                ListeningBar(model:model,presentation:presentation,colour:colour(model.listen.speaker.flatMap { meeting.speaker(for:$0) }?.colourIndex ?? 0))
                    .transition(reduceMotion ? .identity : .move(edge:.bottom).combined(with:.opacity))
            }
            Divider()
            playerBar
        }
        .animation(reduceMotion ? nil : .easeInOut(duration:0.16),value:model.listen.active)
        .font(.system(size: 13))
        .background(Color(nsColor: .textBackgroundColor))
        .accessibilityElement(children: .contain).accessibilityIdentifier("meeting-page")
        .focusedSceneValue(\.listeningMeeting,model)
    }
    /// D70: independent Play target, also available for directly opened/read-only meetings.
    private func speakerRow(_ speaker: MeetingSpeaker) -> some View {
        let turns = model.listen.turns(of:speaker.id)
        let row = SpeakerRowPresentation(speaker:speaker,turns:turns,percent:shares[speaker.id,default:0],
                                         language:UXText.language,locale:UXText.locale)
        let listening = model.listen.speaker.map { meeting.mergedInto[$0] ?? $0 } == speaker.id
        return HStack(alignment:.top,spacing:10) {
            Circle().fill(colour(speaker.colourIndex)).frame(width:10,height:10).padding(.top,5).accessibilityHidden(true)
            VStack(alignment:.leading,spacing:3) {
                HStack(spacing:6) {
                    Text(speaker.displayName).fontWeight(.semibold).lineLimit(1)
                    Spacer(minLength:2)
                    Text(row.share).font(.system(size:11.5)).monospacedDigit().foregroundStyle(.secondary).fixedSize()
                    Button { model.toggleSpeakerListening(speaker.id) } label: {
                        Image(systemName:listening ? "stop.fill" : "play.fill").frame(width:24,height:24)
                    }.buttonStyle(.borderless)
                        .disabled(!model.canPlay || (!listening && turns.isEmpty))
                        .help(UXText.text(listening ? "common.stop" : "speakers.listen"))
                        .accessibilityLabel(listening ? UXText.text("common.stop") : row.playAccessibilityLabel)
                        .accessibilityIdentifier("speaker-listen-" + speaker.id)
                }
                if let caption = row.caption {
                    HStack(spacing:0) {
                        if let provenance = row.provenance, let suffix = row.captionSuffix {
                            Text(provenance).truncationMode(.tail)
                            Text(suffix).truncationMode(.head).layoutPriority(1)
                        } else { Text(caption).truncationMode(.head) }
                    }.font(.system(size:11.5)).monospacedDigit().foregroundStyle(.secondary).lineLimit(1)
                        .help(caption)
                        .accessibilityLabel(caption)
                }
            }
        }.padding(.vertical,4).padding(.horizontal,5)
            .background(listening ? Color.accentColor.opacity(0.08) : .clear)
            .overlay(alignment:.leading) {
                if listening { Rectangle().fill(Color.accentColor).frame(width:3).accessibilityHidden(true) }
            }
            .accessibilityElement(children:.contain).accessibilityLabel(row.accessibilityLabel)
            .accessibilityIdentifier("speaker-row-" + speaker.id)
    }
    private var autoTag: some View {
        Text(UXText.text("common.autoTag")).font(.system(size: 10.5)).foregroundStyle(.secondary).padding(.horizontal, 4)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))
            .help(UXText.text("common.autoTag.tooltip"))
    }
    private var issueLine: String? {
        if meeting.state.transcript == .failed { return "errors.transcribeFailed.line" }
        if meeting.state.transcript == .damaged { return "errors.transcriptDamaged.line" }
        return nil
    }
    private var companionCard: some View {
        HStack(alignment: .top, spacing: 15) {
            Image(systemName: "macwindow").foregroundStyle(Color.accentColor).font(.system(size: 18)).padding(.top, 3).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(UXText.text("meeting.companionCard.title")).fontWeight(.semibold)
                Text(UXText.text("meeting.companionCard.body")).lineSpacing(4)
                HStack(spacing: 16) {
                    Button(UXText.text("meeting.companionCard.setUp")) {
                        CompanionSetup.shared.presenter = .library
                    }.buttonStyle(.plain).fontWeight(.semibold).foregroundStyle(.white)
                        .padding(.horizontal, 14).frame(height: 32).background(Color.accentColor, in: RoundedRectangle(cornerRadius: 6))
                    Button(UXText.text("common.notNow")) { suggestionDismissed = true }.buttonStyle(.plain).foregroundStyle(Color.accentColor)
                }.padding(.top, 6)
            }
            Spacer(minLength: 0)
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.accentColor.opacity(0.11), in: RoundedRectangle(cornerRadius: 7))
            .accessibilityElement(children: .contain).accessibilityLabel(UXText.text("meeting.companionCard.a11y")).accessibilityIdentifier("meeting-companion-card")
    }
    private var playerBar: some View {
        HStack(spacing: 16) {
            Button { model.skip(-10) } label: { Image(systemName: "gobackward.10").frame(width: 24, height: 36) }.help(UXText.text("player.back10")).accessibilityLabel(UXText.text("player.back10"))
            Button { model.toggle() } label: {
                Image(systemName: model.isPlaying ? "pause.fill" : "play.fill").foregroundStyle(.white).frame(width: 44, height: 44)
                    .background(Color.accentColor, in: Circle())
            }.accessibilityLabel(UXText.text(model.isPlaying ? "player.pause" : "common.play")).accessibilityIdentifier("meeting-play")
            Button { model.skip(10) } label: { Image(systemName: "goforward.10").frame(width: 24, height: 36) }.help(UXText.text("player.forward10")).accessibilityLabel(UXText.text("player.forward10"))
            Text(LibraryFormat.position(Int64(model.positionMs))).monospacedDigit().foregroundStyle(.secondary).font(.system(size: 11.5)).accessibilityIdentifier("meeting-elapsed")
            MeetingPositionSlider(position:Binding(get:{ Double(model.positionMs) },set:{ model.seek(Int($0)) }),duration:Double(max(1,model.durationMs)),
                                  readout:model.timelineReadout,names:meeting.speakerDisplayNames,
                                  timeline:model.listen.timeline)
                .frame(minWidth:80,maxWidth:.infinity).frame(height:22)
            Text(LibraryFormat.position(Int64(model.durationMs))).monospacedDigit().foregroundStyle(.secondary).font(.system(size: 11.5))
            Button(UXText.text("format.playbackRate", ["rate": model.rate.formatted(.number.precision(.fractionLength(0...2)).locale(UXText.locale))])) { model.cycleRate() }
                .fontWeight(.semibold).padding(.horizontal, 9).frame(height: 30).background(Color.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 5))
                .accessibilityIdentifier("meeting-speed")
                .accessibilityLabel(UXText.text("player.speed.a11y",["rate":UXText.text("format.playbackRate",["rate":model.rate.formatted(.number.precision(.fractionLength(0...2)).locale(UXText.locale))])]))
        }.buttonStyle(.plain).padding(.horizontal, 24).frame(height: 64).background(Color(nsColor: .windowBackgroundColor))
            .disabled(!model.canPlay).accessibilityElement(children: .contain).accessibilityLabel(UXText.text("player.a11y"))
    }
}

struct NoSpeechTranscriptLine: View {
    let action: (() -> Void)?
    /// The meeting page passes its meeting: when Recording details would show the D58.3 hint (a
    /// fully silent native This computer side), the same hint and action follow this line (L2).
    var meeting: LibraryMeeting? = nil
    @State private var permissionHint = false
    var body: some View {
        VStack(alignment:.leading,spacing:6) {
            HStack(alignment:.firstTextBaseline,spacing:12) {
                Text(UXText.text("transcript.noSpeech")).foregroundStyle(.secondary)
                    .fixedSize(horizontal:false,vertical:true).frame(maxWidth:.infinity,alignment:.leading)
                    .accessibilityIdentifier("transcript-no-speech")
                if let action {
                    Button(UXText.text("transcript.writeDownAgain"),action:action).buttonStyle(.bordered)
                        .disabled(LibraryMoveCoordinator.shared.busy)
                        .accessibilityIdentifier("transcript-write-down-again")
                }
            }
            if permissionHint {
                HStack(alignment:.firstTextBaseline,spacing:12) {
                    Text(UXText.text("details.sources.silent.othersPermissionHint")).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal:false,vertical:true).frame(maxWidth:.infinity,alignment:.leading)
                        .accessibilityIdentifier("transcript-no-speech-permission-hint")
                    Button(UXText.text("errors.othersPermission.action")) { CaptureSettings.open(.others) }
                        .accessibilityIdentifier("transcript-no-speech-permission-settings")
                }
            }
        }
        .task(id:meeting.map { "\($0.folder.path)#\($0.state.transcript)" }) { await loadHint() }
    }
    /// The same derivation as Recording details, read off the main actor.
    private func loadHint() async {
        // A reused view never shows the previous meeting's hint while this one is read.
        permissionHint = false
        guard let meeting else { return }
        let folder = meeting.folder, lifecycle = RecordingDetailsReport.Lifecycle(meeting.state.lifecycle)
        let title = meeting.title ?? "", done = meeting.state.transcript == .done
        let shows = await Task.detached {
            RecordingDetailsReport(.load(folder:folder,lifecycle:lifecycle,title:title,transcriptDone:done)).showsPermissionHint
        }.value
        guard !Task.isCancelled else { return }
        permissionHint = shows
    }
}

struct InlineMeetingLine: View {
    let id: String
    var info = false
    var actionID: String?
    let action: (() -> Void)?
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: info ? "info.circle" : "exclamationmark.triangle")
            Text(UXText.text(id)).fontWeight(.semibold).frame(maxWidth: .infinity, alignment: .leading)
            if let actionID, let action { Button(UXText.text(actionID), action: action).buttonStyle(.bordered) }
        }.padding(12).foregroundStyle(info ? Color.accentColor : Color(red: 122/255, green: 77/255, blue: 0))
            .background(info ? Color.accentColor.opacity(0.11) : Color(red: 1, green: 240/255, blue: 199/255), in: RoundedRectangle(cornerRadius: 7))
    }
}
