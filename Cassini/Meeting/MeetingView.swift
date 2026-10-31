// SPDX-License-Identifier: GPL-3.0-or-later
import CassiniLibrary
import SwiftUI

struct MeetingView: View {
    @Bindable var model: MeetingDetailModel
    let format: LibraryFormat
    @AppStorage("CassiniCompanionSuggestionDismissed") private var suggestionDismissed = false
    var showsCompanionSuggestion: Bool { !suggestionDismissed && !CaptureCollection.shared.connected }
    private var meeting: LibraryMeeting { model.meeting }
    private var shares: [String: Int] { model.shares }
    private var currentTurn: Int? {
        model.turns.last { turn in
            turn.items.contains { $0.startMs <= model.positionMs && model.positionMs < $0.endMs }
        }?.id
    }
    private func colour(_ index: Int) -> Color {
        [Color.accentColor, Color(red: 179/255, green: 71/255, blue: 0), Color(red: 125/255, green: 60/255, blue: 152/255)][index % 3]
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 18) {
                    Text(UXText.text("common.speakers")).font(.system(size: 11.5, weight: .bold)).foregroundStyle(.secondary)
                    ForEach(meeting.speakers, id: \.id) { speaker in
                        HStack(alignment: .top, spacing: 10) {
                            Circle().fill(colour(speaker.colourIndex)).frame(width: 10, height: 10).padding(.top, 3)
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Text(speaker.displayName).fontWeight(.semibold)
                                    Spacer(minLength: 2)
                                    Text(UXText.text("meeting.speakerShare", ["percent": String(shares[speaker.id, default: 0])])).font(.system(size: 11.5)).monospacedDigit().foregroundStyle(.secondary)
                                }
                                if let caption = caption(speaker) { Text(UXText.text(caption)).font(.system(size: 11.5)).foregroundStyle(.secondary) }
                            }
                        }
                    }
                    Spacer(minLength: 0)
                }.padding(.horizontal, 19).padding(.top, 14)
                    .frame(width: 260).frame(maxHeight: .infinity)
                    .background(LibraryTheme.sidebar)
                    .accessibilityElement(children: .contain).accessibilityLabel(UXText.text("meeting.speakersPane.a11y"))
                Divider()
                ScrollViewReader { proxy in ScrollView {
                    LazyVStack(alignment: .leading, spacing: 22) {
                        if meeting.hasNoSpeech {
                            NoSpeechTranscriptLine(action:meeting.canWriteDown ? { TranscriptionQueue.shared.writeDown(model) } : nil)
                                .disabled(LibraryMoveCoordinator.shared.busy)
                        }
                        if let line = issueLine { InlineMeetingLine(id: line, actionID: meeting.state.transcript == .failed ? "common.tryAgain" : nil, action: meeting.state.transcript == .failed ? { TranscriptionQueue.shared.writeDown(model) } : nil).disabled(LibraryMoveCoordinator.shared.busy) }
                        if showsCompanionSuggestion { companionCard }
                        ForEach(model.turns) { turn in
                            HStack(alignment: .top, spacing: 16) {
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack(spacing: 5) {
                                        Text(meeting.speakers.first { $0.id == turn.speaker }?.displayName ?? "")
                                            .fontWeight(.semibold).foregroundStyle(colour(meeting.speakers.first { $0.id == turn.speaker }?.colourIndex ?? 0))
                                        if meeting.speakers.first(where: { $0.id == turn.speaker })?.provenance == .recognised { autoTag }
                                    }.fixedSize()
                                    Text(LibraryFormat.position(turn.startMs)).font(.system(size: 11.5)).foregroundStyle(.secondary).monospacedDigit()
                                }.frame(width: 120, alignment: .leading)
                                MeetingTranscriptText(items:turn.items,positionMs:model.positionMs,seek:model.seek)
                                    .frame(maxWidth:.infinity,alignment:.leading)
                            }.id(turn.id)
                                .accessibilityElement(children:.ignore)
                                .accessibilityLabel([meeting.speakers.first(where:{ $0.id == turn.speaker })?.displayName ?? "",LibraryFormat.position(turn.startMs),turn.items.map(\.text).joined(separator:" ")].joined(separator:", "))
                                .accessibilityIdentifier("meeting-turn-" + String(turn.id))
                                .accessibilityAction(named:Text(UXText.text("player.playFromHere"))) { model.playFrom(Int(turn.startMs)) }
                        }
                    }.padding(.horizontal, 48).padding(.vertical, 22)
                }.accessibilityIdentifier("meeting-transcript")
                    .task {
                        await Task.yield()
                        if let turn = currentTurn { proxy.scrollTo(turn,anchor:.center) }
                    }
                    .onChange(of: currentTurn) { _, turn in
                        if let turn { withAnimation { proxy.scrollTo(turn, anchor: .center) } }
                    }
                }
            }
            Divider()
            playerBar
        }
        .font(.system(size: 13))
        .background(Color(nsColor: .textBackgroundColor))
        .accessibilityElement(children: .contain).accessibilityIdentifier("meeting-page")
    }
    private func caption(_ speaker: MeetingSpeaker) -> String? {
        switch speaker.provenance {
        case .user: return "meeting.speakerCaption.namedByYou"
        case .recognised: return "meeting.speakerCaption.recognised"
        case .unnamed: return "meeting.speakerCaption.notNamed"
        case .source: return speaker.id == "me" ? "common.yourMicrophone" : (speaker.id == "others" ? "recordFirst.sound.title" : nil)
        case nil: return speaker.name == nil ? "meeting.speakerCaption.notNamed" : nil
        }
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
            MeetingPositionSlider(position:Binding(get:{ Double(model.positionMs) },set:{ model.seek(Int($0)) }),duration:Double(max(1,model.durationMs)))
                .frame(minWidth:80,maxWidth:.infinity).frame(height:22)
            Text(LibraryFormat.position(Int64(model.durationMs))).monospacedDigit().foregroundStyle(.secondary).font(.system(size: 11.5))
            Button(UXText.text("format.playbackRate", ["rate": model.rate.formatted(.number.precision(.fractionLength(0...2)).locale(Locale(identifier: "en_GB")))])) { model.cycleRate() }
                .fontWeight(.semibold).padding(.horizontal, 9).frame(height: 30).background(Color.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 5))
                .accessibilityIdentifier("meeting-speed")
                .accessibilityLabel(UXText.text("player.speed.a11y",["rate":UXText.text("format.playbackRate",["rate":model.rate.formatted(.number.precision(.fractionLength(0...2)).locale(Locale(identifier:"en_GB")))])]))
        }.buttonStyle(.plain).padding(.horizontal, 24).frame(height: 64).background(Color(nsColor: .windowBackgroundColor))
            .disabled(!model.canPlay).accessibilityElement(children: .contain).accessibilityLabel(UXText.text("player.a11y"))
    }
}

/// NSSlider permits a string accessibility value. Keep its numeric thumb model
/// while exposing time (SwiftUI's value modifier leaves the millisecond number).
private struct MeetingPositionSlider: NSViewRepresentable {
    @Binding var position: Double
    let duration: Double
    @Environment(\.isEnabled) private var isEnabled
    final class Coordinator: NSObject {
        var seek: (Double) -> Void
        init(seek: @escaping (Double) -> Void) { self.seek = seek }
        @objc func changed(_ sender: NSSlider) { seek(sender.doubleValue) }
    }
    func makeCoordinator() -> Coordinator { Coordinator { position = $0 } }
    func makeNSView(context: Context) -> TimeSlider {
        let slider = TimeSlider()
        slider.isContinuous = true; slider.target = context.coordinator
        slider.action = #selector(Coordinator.changed(_:))
        slider.setAccessibilityIdentifier("meeting-seek")
        slider.setAccessibilityLabel(UXText.text("player.position"))
        return slider
    }
    func updateNSView(_ slider: TimeSlider, context: Context) {
        context.coordinator.seek = { position = $0 }
        slider.minValue = 0; slider.maxValue = duration
        slider.doubleValue = min(duration,max(0,position)); slider.isEnabled = isEnabled
    }
    final class TimeSlider: NSSlider {
        override func accessibilityValue() -> Any? { LibraryFormat.position(Int64(doubleValue)) }
        override func accessibilityValueDescription() -> String? { LibraryFormat.position(Int64(doubleValue)) }
        override func setAccessibilityValue(_ value: Any?) {
            if let number = value as? NSNumber { _ = apply(number.doubleValue) }
            else if let text = value as? String {
                let fields = text.split(separator:":",omittingEmptySubsequences:false)
                let parts = fields.compactMap { Double($0) }
                if fields.count == 3, parts.count == 3, parts[0] >= 0, (0..<60).contains(parts[1]), (0..<60).contains(parts[2]) {
                    _ = apply(parts[0]*3600000 + parts[1]*60000 + parts[2]*1000)
                }
            }
        }
        override func accessibilityPerformIncrement() -> Bool { apply(doubleValue + 10000) }
        override func accessibilityPerformDecrement() -> Bool { apply(doubleValue - 10000) }
        private func apply(_ value: Double) -> Bool {
            guard isEnabled, value.isFinite else { return false }
            let position = min(maxValue,max(minValue,value))
            guard position != doubleValue else { return false }
            doubleValue = position; sendAction(action,to:target)
            return true
        }
    }
}

struct NoSpeechTranscriptLine: View {
    let action: (() -> Void)?
    var body: some View {
        HStack(alignment:.firstTextBaseline,spacing:12) {
            Text(UXText.text("transcript.noSpeech")).foregroundStyle(.secondary)
                .fixedSize(horizontal:false,vertical:true).frame(maxWidth:.infinity,alignment:.leading)
                .accessibilityIdentifier("transcript-no-speech")
            if let action {
                Button(UXText.text("transcript.writeDownAgain"),action:action).buttonStyle(.bordered)
                    .accessibilityIdentifier("transcript-write-down-again")
            }
        }
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
