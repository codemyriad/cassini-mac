// SPDX-License-Identifier: GPL-3.0-or-later
import CassiniLibrary
import SwiftUI

struct MeetingView: View {
    @Bindable var model: MeetingDetailModel
    let format: LibraryFormat
    @AppStorage("CassiniCompanionSuggestionDismissed", store: RecordingPreferences.defaults) private var suggestionDismissed = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var handScrolling = false
    var showsCompanionSuggestion: Bool { !suggestionDismissed && !CaptureCollection.shared.connected }
    private var meeting: LibraryMeeting { model.meeting }
    private var isTranscribing: Bool {
        TranscribingPresentation.isActive(meeting.state)
    }
    private var shares: [String: Int] { model.shares }
    /// M11: paragraphs only; an aside is shown inside its host.
    private var visibleTurns: [MeetingPresentation.Turn] { MeetingPresentation.visibleTurns(model.turns) }
    private func name(_ speaker: String) -> String { model.speakerName(speaker) }
    private func asides(_ turn: MeetingPresentation.Turn) -> [MeetingTranscriptText.Aside] {
        turn.asides.compactMap { aside in
            guard model.turns.indices.contains(aside.turn) else { return nil }
            let asideTurn = model.turns[aside.turn]
            let speaker = meeting.speaker(for:asideTurn.speaker)
            return .init(id:aside.turn,listeningWords:model.transcriptListening.words(in:aside.turn,listeningTo:model.listen.turn?.index),
                         after:aside.after,name:name(asideTurn.speaker),items:asideTurn.items,
                         speakerInk:CassiniTheme.nsSpeakerInk(speaker),speakerWash:CassiniTheme.nsSpeakerWash(speaker))
        }
    }
    /// D55.1 meeting.turn.over: the other speakers whose words overlap this turn.
    private func over(_ turn: MeetingPresentation.Turn) -> String? {
        let names = meeting.overlappingSpeakerIDs(turn.over,excluding:turn.speaker).map(name)
        return names.isEmpty ? nil : UXText.text("meeting.turn.over",["names":LibraryFormat(locale:UXText.locale,language:UXText.language).list(names)])
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
    private func colour(_ speaker: MeetingSpeaker?) -> Color {
        CassiniTheme.speakerInk(speaker)
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
            turnHeader(turn)
            turnText(turn)
                .frame(maxWidth:.infinity,alignment:.leading)
        }.id(turn.id)
            .overlay(alignment:.leading) {
                if !model.transcriptListening.words(in:turn.id,listeningTo:model.listen.turn?.index).isEmpty {
                    Rectangle().fill(CassiniTheme.accent).frame(width:3).padding(.leading,-8).accessibilityHidden(true)
                }
            }
            .focusable(isEnabled)
            .focusedValue(\.playTranscriptTurn,{
                if model.canUseTranscriptShortcuts { model.playFrom(Int(turn.startMs)) }
            })
            .onKeyPress(keys:[.return,KeyEquivalent("\u{03}")],phases:.down) { event in
                guard event.modifiers == .shift, model.canUseTranscriptShortcuts else { return .ignored }
                model.playFrom(Int(turn.startMs)); return .handled
            }
            .accessibilityElement(children:.contain)
            .accessibilityLabel(turnLabel(turn))
            .accessibilityHint(over(turn) == nil ? "" : UXText.text("meeting.turn.over.tooltip"))
            .accessibilityIdentifier("meeting-turn-" + String(turn.id))
            .accessibilityAction(named:Text(UXText.text("player.playFromHere"))) { model.playFrom(Int(turn.startMs)) }
    }
    private func turnHeader(_ turn: MeetingPresentation.Turn) -> some View {
        VStack(alignment: .leading, spacing: 4) {
                if !turn.continuation { HStack(spacing: 5) {
                    Button { model.listenFromReadingTurn(turn.id) } label: {
                        Text(name(turn.speaker)).fontWeight(.semibold)
                            .foregroundStyle(colour(meeting.speaker(for:turn.speaker)))
                    }.buttonStyle(.borderless).disabled(!model.canPlay)
                        .help(UXText.text("listen.speakerName.tooltip",["name":name(turn.speaker)]))
                        .accessibilityLabel(UXText.text("listen.speakerName.tooltip",["name":name(turn.speaker)]))
                        .accessibilityIdentifier("turn-listen-\(turn.id)")
                        .focusable(isEnabled)
                        .onKeyPress(keys:[.return,KeyEquivalent("\u{03}")],phases:.down) { event in
                            guard event.modifiers.isEmpty, model.canUseTranscriptShortcuts else { return .ignored }
                            model.listenFromReadingTurn(turn.id); return .handled
                        }
                    if meeting.speaker(for:turn.speaker)?.provenance == .recognised { autoTag }
                }.fixedSize() }
                Button { model.playFrom(Int(turn.startMs)) } label: {
                    Text(LibraryFormat.position(turn.startMs)).font(.system(size:11.5)).foregroundStyle(CassiniTheme.secondaryInk).monospacedDigit()
                }.buttonStyle(.borderless).disabled(!model.canPlay)
                    .help(UXText.text("player.playFromHere"))
                    .accessibilityLabel(UXText.text("player.playFromHere") + ", " + LibraryFormat.position(turn.startMs))
                    .accessibilityIdentifier("turn-play-\(turn.id)")
                    .focusable(isEnabled)
                    .onKeyPress(keys:[.return,KeyEquivalent("\u{03}")],phases:.down) { event in
                        guard event.modifiers.isEmpty, model.canUseTranscriptShortcuts else { return .ignored }
                        model.playFrom(Int(turn.startMs)); return .handled
                    }
                if let over = over(turn) {
                    Text(over).font(.system(size: 11.5)).foregroundStyle(CassiniTheme.secondaryInk)
                        .help(UXText.text("meeting.turn.over.tooltip"))
                }
            }.frame(width: 120, alignment: .leading)
    }
    private func turnText(_ turn: MeetingPresentation.Turn) -> MeetingTranscriptText {
        MeetingTranscriptText(items:turn.items,asides:asides(turn),positionMs:model.positionMs,seek:model.seek,
                                  listeningWords:model.transcriptListening.words(in:turn.id,listeningTo:model.listen.turn?.index),
                                  canPlay:model.canPlay,listen:model.listenFromReadingTurn,playFromHere:{
                                      if model.canUseTranscriptShortcuts { model.playFrom(Int(turn.startMs)) }
                                  })
    }
    /// The speakers column, kept out of `body` for the Xcode 16.4 type checker.
    private var speakersPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(meeting.speakers, id: \.id) { speaker in speakerRow(speaker).id(speaker.id) }
                    }
                    .padding(.horizontal, 19)
                }
                .cassiniTopScrollEdge()
                .cassiniPinnedTopBar(alignment: .leading) {
                    Text(UXText.text("common.speakers"))
                        .font(.system(size: 11.5, weight: .bold))
                        .foregroundStyle(CassiniTheme.secondaryInk)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 19)
                        .padding(.top, 14)
                        .padding(.bottom, 18)
                }
                .onChange(of: model.listen.speaker) { _, speaker in
                    if let speaker = speaker.flatMap({ meeting.speaker(for:$0) }) {
                        if reduceMotion { proxy.scrollTo(speaker.id,anchor:.center) }
                        else { withAnimation { proxy.scrollTo(speaker.id,anchor:.center) } }
                    }
                }
            }
            Button(UXText.text("meeting.nameSpeakers")) {
                MeetingRenameCoordinator.shared.showSpeaker(meeting,id:model.listen.speaker ?? model.namingSpeakerID)
            }.buttonStyle(.borderless).disabled(!MeetingRenameCoordinator.shared.canEditSpeakers(meeting) || meeting.speakers.isEmpty)
                .accessibilityIdentifier("name-the-speakers")
                .padding(.horizontal, 19)
                .padding(.vertical, 18)
        }
            .frame(width: 260).frame(maxHeight: .infinity)
            .cassiniSidebarBackground()
            .accessibilityElement(children: .contain).accessibilityLabel(UXText.text("meeting.speakersPane.a11y"))
    }
    var body: some View {
        VStack(spacing: 0) {
            if isTranscribing {
                TranscribingStatusView(meeting:meeting)
                Divider()
            }
            HStack(spacing: 0) {
                if !isTranscribing {
                    speakersPane
                    CassiniColumnDivider()
                }
                ScrollViewReader { proxy in ScrollView {
                    LazyVStack(alignment: .leading, spacing: 22) {
                        if meeting.hasNoSpeech {
                            // A Library move disables Write down again only (the line disables it); the
                            // permission hint's Open System Settings stays available, as in Recording details.
                            NoSpeechTranscriptLine(action:meeting.canWriteDown ? { TranscriptionQueue.shared.writeDown(model) } : nil,meeting:meeting)
                        }
                        if let line = issueLine { InlineMeetingLine(id: line, actionID: meeting.state.transcript == .failed ? "common.tryAgain" : nil, action: meeting.state.transcript == .failed ? { TranscriptionQueue.shared.writeDown(model) } : nil).disabled(LibraryMoveCoordinator.shared.busy) }
                        if !isTranscribing {
                            if showsCompanionSuggestion { companionCard }
                            ForEach(visibleTurns) { turn in turnRow(turn) }
                        }
                    }.padding(.horizontal, 48).padding(.vertical, 22)
                }.cassiniTopScrollEdge()
                    .accessibilityIdentifier("meeting-transcript")
                    .onScrollPhaseChange { _,phase in
                        handScrolling = phase == .tracking || phase == .interacting || phase == .decelerating
                    }
                    .onScrollGeometryChange(for:CGFloat.self) { $0.contentOffset.y } action: { _,_ in
                        if handScrolling { model.handScrolledTranscript() }
                    }
                    .task {
                        await Task.yield()
                        if let turn = model.listeningHost ?? currentTurn { proxy.scrollTo(turn,anchor:.center) }
                    }
                    .onChange(of:model.followRevision) { _,_ in
                        if let host = model.listeningHost {
                            if reduceMotion { proxy.scrollTo(host,anchor:.center) }
                            else { withAnimation { proxy.scrollTo(host,anchor:.center) } }
                        }
                    }
                    .onChange(of:model.listen.turn?.index) { _,_ in
                        if model.canFollowTranscript, let host = model.listeningHost {
                            if reduceMotion { proxy.scrollTo(host,anchor:.center) }
                            else { withAnimation { proxy.scrollTo(host,anchor:.center) } }
                        }
                    }
                    .onChange(of: currentTurn) { _, turn in
                        if model.canFollowTranscript, let turn = model.transcriptListening.followHost(forReading:turn,listeningTo:model.listen.turn?.index) {
                            if reduceMotion { proxy.scrollTo(turn,anchor:.center) }
                            else { withAnimation { proxy.scrollTo(turn,anchor:.center) } }
                        }
                    }
                }
            }
            // Keep the controls in the main layout/hit-test tree. On macOS 15,
            // safeAreaInset paints this bar but its buttons fail AX hit testing.
            if !isTranscribing, let presentation = model.listeningPresentation {
                ListeningBar(model:model,presentation:presentation,colour:colour(model.listen.speaker.flatMap { meeting.speaker(for:$0) }))
                    .transition(reduceMotion ? .identity : .move(edge:.bottom).combined(with:.opacity))
            }
            Divider()
            playerBar
        }
        .animation(reduceMotion ? nil : .easeInOut(duration:0.16),value:model.listen.active)
        .font(.system(size: 13))
        .background(CassiniTheme.paneGround)
        .accessibilityElement(children: .contain).accessibilityIdentifier("meeting-page")
        .focusedSceneValue(\.listeningMeeting,model)
    }
    /// D70: independent Play target, also available for directly opened/read-only meetings.
    private func speakerRow(_ speaker: MeetingSpeaker) -> some View {
        let turns = model.listen.turns(of:speaker.id)
        let row = SpeakerRowPresentation(speaker:speaker,turns:turns,percent:shares[speaker.id,default:0],
                                         language:UXText.language,locale:UXText.locale)
        let listening = model.listen.speaker.map { meeting.mergedInto[$0] ?? $0 } == speaker.id
        return SpeakerSidebarRow(
            speaker:speaker,
            row:row,
            colour:colour(speaker),
            listening:listening,
            canEdit:MeetingRenameCoordinator.shared.canEditSpeakers(meeting),
            canPlay:model.canPlay && (listening || !turns.isEmpty),
            onName:{ MeetingRenameCoordinator.shared.showSpeaker(meeting,id:speaker.id) },
            onToggleListen:{ model.toggleSpeakerListening(speaker.id) }
        )
    }
    private var autoTag: some View {
        Text(UXText.text("common.autoTag")).font(.system(size: 10.5)).foregroundStyle(CassiniTheme.secondaryInk).padding(.horizontal, 4)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(CassiniTheme.secondaryTagStroke))
            .help(UXText.text("common.autoTag.tooltip"))
    }
    private var issueLine: String? {
        if meeting.state.transcript == .failed { return "errors.transcribeFailed.line" }
        if meeting.state.transcript == .damaged { return "errors.transcriptDamaged.line" }
        return nil
    }
    private var companionCard: some View {
        HStack(alignment: .top, spacing: 15) {
            Image(systemName: "macwindow").foregroundStyle(CassiniTheme.accentInk).font(.system(size: 18)).padding(.top, 3).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(UXText.text("meeting.companionCard.title")).fontWeight(.semibold)
                Text(UXText.text("meeting.companionCard.body")).lineSpacing(4)
                HStack(spacing: 16) {
                    Button(UXText.text("meeting.companionCard.setUp")) {
                        CompanionSetup.shared.presenter = .library
                    }.buttonStyle(.plain).fontWeight(.semibold).foregroundStyle(CassiniTheme.onAccent)
                        .padding(.horizontal, 14).frame(height: 32).background(CassiniTheme.accentStrong, in: RoundedRectangle(cornerRadius: 6))
                    Button(UXText.text("common.notNow")) { suggestionDismissed = true }.buttonStyle(.plain).foregroundStyle(CassiniTheme.accentInk)
                }.padding(.top, 6)
            }
            Spacer(minLength: 0)
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(CassiniTheme.accentTint, in: RoundedRectangle(cornerRadius: 7))
            .accessibilityElement(children: .contain).accessibilityLabel(UXText.text("meeting.companionCard.a11y")).accessibilityIdentifier("meeting-companion-card")
    }
    private var playerBar: some View {
        HStack(spacing: 16) {
            Button { model.skip(-10) } label: { Image(systemName: "gobackward.10").frame(width: 24, height: 36) }.help(UXText.text("player.back10")).accessibilityLabel(UXText.text("player.back10"))
            Button { model.toggle() } label: {
                Image(systemName: model.isPlaying ? "pause.fill" : "play.fill").foregroundStyle(CassiniTheme.onAccent).frame(width: 44, height: 44)
                    .background(CassiniTheme.accentStrong, in: Circle())
            }.accessibilityLabel(UXText.text(model.isPlaying ? "player.pause" : "common.play")).accessibilityIdentifier("meeting-play")
            Button { model.skip(10) } label: { Image(systemName: "goforward.10").frame(width: 24, height: 36) }.help(UXText.text("player.forward10")).accessibilityLabel(UXText.text("player.forward10"))
            Text(LibraryFormat.position(Int64(model.positionMs))).monospacedDigit().foregroundStyle(CassiniTheme.secondaryInk).font(.system(size: 11.5)).accessibilityIdentifier("meeting-elapsed")
            MeetingPositionSlider(position:Binding(get:{ Double(model.positionMs) },set:{ model.seek(Int($0)) }),duration:Double(max(1,model.durationMs)),
                                  readout:isTranscribing ? TimelineReadout() : model.timelineReadout,
                                  names:isTranscribing ? [:] : meeting.speakerDisplayNames,
                                  timeline:isTranscribing ? ListeningTimeline() : model.listen.timeline)
                .frame(minWidth:80,maxWidth:.infinity).frame(height:22)
            Text(LibraryFormat.position(Int64(model.durationMs))).monospacedDigit().foregroundStyle(CassiniTheme.secondaryInk).font(.system(size: 11.5))
            Button(UXText.text("format.playbackRate", ["rate": model.rate.formatted(.number.precision(.fractionLength(0...2)).locale(UXText.locale))])) { model.cycleRate() }
                .fontWeight(.semibold).padding(.horizontal, 9).frame(height: 30).background(CassiniTheme.ratePillFill, in: RoundedRectangle(cornerRadius: 5))
                .accessibilityIdentifier("meeting-speed")
                .accessibilityLabel(UXText.text("player.speed.a11y",["rate":UXText.text("format.playbackRate",["rate":model.rate.formatted(.number.precision(.fractionLength(0...2)).locale(UXText.locale))])]))
        }.buttonStyle(.plain).padding(.horizontal, 24).frame(height: 64).background(CassiniTheme.windowGround)
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
                Text(UXText.text("transcript.noSpeech")).foregroundStyle(CassiniTheme.secondaryInk)
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
                    Text(UXText.text("details.sources.silent.othersPermissionHint")).font(.callout).foregroundStyle(CassiniTheme.secondaryInk)
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
        }.padding(12).foregroundStyle(info ? CassiniTheme.accentInk : CassiniTheme.inlineWarnInk)
            .background(info ? CassiniTheme.accentTint : CassiniTheme.inlineWarnTint, in: RoundedRectangle(cornerRadius: 7))
    }
}

struct SpeakerSidebarRow: View {
    let speaker: MeetingSpeaker
    let row: SpeakerRowPresentation
    let colour: Color
    let listening: Bool
    let canEdit: Bool
    let canPlay: Bool
    let onName: () -> Void
    let onToggleListen: () -> Void
    var body: some View {
        HStack(alignment:.top,spacing:10) {
            Circle().fill(colour).frame(width:10,height:10).padding(.top,5).accessibilityHidden(true)
            VStack(alignment:.leading,spacing:3) {
                HStack(spacing:6) {
                    if canEdit {
                        Button(action:onName) {
                            HStack(spacing:6) {
                                Text(speaker.displayName).fontWeight(.semibold).foregroundStyle(CassiniTheme.primaryInk).lineLimit(1)
                                Spacer(minLength:2)
                                Text(row.share).font(.system(size:11.5)).monospacedDigit().foregroundStyle(CassiniTheme.secondaryInk).fixedSize()
                            }.contentShape(Rectangle())
                        }.buttonStyle(.plain)
                            .accessibilityLabel(row.accessibilityLabel)
                            .accessibilityValue(row.share)
                            .accessibilityIdentifier("speaker-name-" + speaker.id)
                    } else {
                        Text(speaker.displayName).fontWeight(.semibold).foregroundStyle(CassiniTheme.primaryInk).lineLimit(1)
                        Spacer(minLength:2)
                        Text(row.share).font(.system(size:11.5)).monospacedDigit().foregroundStyle(CassiniTheme.secondaryInk).fixedSize()
                    }
                    Button(action:onToggleListen) {
                        Image(systemName:listening ? "stop.fill" : "play.fill").frame(width:24,height:24)
                    }.buttonStyle(.borderless)
                        .disabled(!canPlay)
                        .help(UXText.text(listening ? "common.stop" : "speakers.listen"))
                        .accessibilityLabel(listening ? UXText.text("common.stop") : row.playAccessibilityLabel)
                        .accessibilityIdentifier("speaker-listen-" + speaker.id)
                }
                if let caption = row.caption {
                    let captionRow = HStack(spacing:0) {
                        if let provenance = row.provenance, let suffix = row.captionSuffix {
                            Text(provenance).truncationMode(.tail)
                            Text(suffix).truncationMode(.head).layoutPriority(1)
                        } else { Text(caption).truncationMode(.head) }
                    }.font(.system(size:11.5)).monospacedDigit().foregroundStyle(CassiniTheme.secondaryInk).lineLimit(1)
                        .frame(maxWidth:.infinity,alignment:.leading)
                        .help(caption)
                        .accessibilityElement(children:.combine)
                        .accessibilityLabel(caption)
                        .accessibilityIdentifier("speaker-caption-" + speaker.id)
                    if canEdit {
                        captionRow.contentShape(Rectangle()).onTapGesture(perform:onName)
                    } else {
                        captionRow
                    }
                }
            }
        }.padding(.vertical,4).padding(.horizontal,5)
            .background(listening ? CassiniTheme.listeningRowWash : .clear)
            .overlay(alignment:.leading) {
                if listening { Rectangle().fill(CassiniTheme.accent).frame(width:3).accessibilityHidden(true) }
            }
            .accessibilityElement(children:.contain).accessibilityLabel(row.accessibilityLabel)
            .accessibilityIdentifier("speaker-row-" + speaker.id)
    }
}

#if DEBUG
extension SpeakerSidebarRow {
    @MainActor static func nativeSelfTest(baseSpeaker: MeetingSpeaker) -> [String:Bool] {
        var speaker = baseSpeaker
        speaker.id = "marta"; speaker.name = "Marta"; speaker.provenance = .user; speaker.colourIndex = 0; speaker.label = nil
        let turns = SpeakerTurn.grouping([
            .init(speaker:"marta",startMs:175_000,endMs:180_000,text:"First."),
            .init(speaker:"giulia",startMs:181_000,endMs:185_000,text:"Reply."),
            .init(speaker:"marta",startMs:200_000,endMs:205_000,text:"Second.")
        ]).filter { $0.speaker == "marta" }
        let presentation = SpeakerRowPresentation(
            speaker:speaker,
            turns:turns,
            percent:43,
            language:.en,
            locale:Locale(identifier:"en_GB")
        )
        func snapshot<Content: View>(_ content: Content, appearanceName: NSAppearance.Name) -> (rep: NSBitmapImageRep, size: CGSize)? {
            guard let appearance = NSAppearance(named:appearanceName) else { return nil }
            let wrapped = ZStack(alignment:.topLeading) {
                CassiniTheme.paneGround
                content.font(.system(size:13)).frame(width:222,alignment:.leading)
            }.environment(\.colorScheme,appearanceName == .darkAqua ? .dark : .light)
            let host = NSHostingView(rootView:wrapped)
            host.appearance = appearance
            var result: (NSBitmapImageRep, CGSize)?
            appearance.performAsCurrentDrawingAppearance {
                let fitting = host.fittingSize
                let size = CGSize(width:222,height:max(44,ceil(fitting.height)))
                host.frame = NSRect(origin:.zero,size:size)
                host.layoutSubtreeIfNeeded()
                guard let rep = host.bitmapImageRepForCachingDisplay(in:host.bounds) else { return }
                host.cacheDisplay(in:host.bounds,to:rep)
                result = (rep,size)
            }
            return result
        }
        func luminance(_ rep: NSBitmapImageRep, x: Int, y: Int) -> Double {
            guard let c = rep.colorAt(x:x,y:y)?.usingColorSpace(.sRGB) else { return 0.5 }
            return 0.2126 * Double(c.redComponent) + 0.7152 * Double(c.greenComponent) + 0.0722 * Double(c.blueComponent)
        }
        func nameInkExtremum(_ snap: (rep: NSBitmapImageRep, size: CGSize), dark: Bool) -> Double {
            let sx = Double(snap.rep.pixelsWide) / Double(snap.size.width)
            let x0 = max(0,Int(24 * sx)), x1 = min(snap.rep.pixelsWide - 1,Int(90 * sx))
            let y0 = 0, y1 = max(1,snap.rep.pixelsHigh / 2)
            var best = dark ? 0.0 : 1.0
            for y in y0..<y1 {
                for x in x0...x1 {
                    let lum = luminance(snap.rep,x:x,y:y)
                    best = dark ? max(best,lum) : min(best,lum)
                }
            }
            return best
        }
        func captionRightEdgePt(_ snap: (rep: NSBitmapImageRep, size: CGSize)) -> Double {
            let sx = Double(snap.rep.pixelsWide) / Double(snap.size.width)
            let bg = luminance(snap.rep,x:snap.rep.pixelsWide - 1,y:snap.rep.pixelsHigh - 1)
            let y0 = snap.rep.pixelsHigh / 2, y1 = snap.rep.pixelsHigh
            var maxX = 0
            for y in y0..<y1 {
                for x in 0..<snap.rep.pixelsWide where abs(luminance(snap.rep,x:x,y:y) - bg) > 0.06 {
                    if x > maxX { maxX = x }
                }
            }
            return Double(maxX) / sx
        }
        let readOnlyView = SpeakerSidebarRow(speaker:speaker,row:presentation,colour:CassiniTheme.speakerInk(speaker),listening:false,canEdit:false,canPlay:true,onName:{},onToggleListen:{})
        let editableView = SpeakerSidebarRow(speaker:speaker,row:presentation,colour:CassiniTheme.speakerInk(speaker),listening:false,canEdit:true,canPlay:true,onName:{},onToggleListen:{})
        let dimmedMutant = HStack(alignment:.top,spacing:10) {
            Circle().fill(CassiniTheme.speakerInk(speaker)).frame(width:10,height:10).padding(.top,5)
            Button {} label: {
                HStack(spacing:6) {
                    Text(speaker.displayName).fontWeight(.semibold).lineLimit(1)
                    Spacer(minLength:2)
                    Text(presentation.share).font(.system(size:11.5)).foregroundStyle(CassiniTheme.secondaryInk)
                }
            }.buttonStyle(.plain).disabled(true)
        }.padding(.vertical,4).padding(.horizontal,5)
        guard let roLight = snapshot(readOnlyView,appearanceName:.aqua),
              let edLight = snapshot(editableView,appearanceName:.aqua),
              let dimLight = snapshot(dimmedMutant,appearanceName:.aqua),
              let roDark = snapshot(readOnlyView,appearanceName:.darkAqua),
              let edDark = snapshot(editableView,appearanceName:.darkAqua),
              let dimDark = snapshot(dimmedMutant,appearanceName:.darkAqua) else {
            return ["speakerRowReadOnlyKeepsPrimaryInk":false,"speakerRowCaptionUsesFullRowWidth":false]
        }
        let roLightInk = nameInkExtremum(roLight,dark:false)
        let edLightInk = nameInkExtremum(edLight,dark:false)
        let dimLightInk = nameInkExtremum(dimLight,dark:false)
        let roDarkInk = nameInkExtremum(roDark,dark:true)
        let edDarkInk = nameInkExtremum(edDark,dark:true)
        let dimDarkInk = nameInkExtremum(dimDark,dark:true)
        let keepsPrimaryInk =
            abs(roLightInk - edLightInk) < 0.03 && roLightInk < 0.25 && dimLightInk > roLightInk + 0.10 &&
            abs(roDarkInk - edDarkInk) < 0.03 && roDarkInk > 0.75 && dimDarkInk < roDarkInk - 0.10
        // With Play on the name/share line, the 222pt sidebar leaves 5..217pt for the row and the
        // caption reaches past 188pt; if Play sat outside VStack (stealing 24 + 10 = 34pt), the
        // caption could never pass 183pt.
        let fullCaptionWidth = captionRightEdgePt(roLight) >= 188.0 && captionRightEdgePt(edLight) >= 188.0
        return [
            "speakerRowReadOnlyKeepsPrimaryInk":keepsPrimaryInk,
            "speakerRowCaptionUsesFullRowWidth":fullCaptionWidth
        ]
    }
}
#endif
