// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import CassiniLibrary

/// Listening controls stay separate from the transcript for Xcode 16.4's type checker.
struct ListeningBar: View {
    @Bindable var model: MeetingDetailModel
    let presentation: ListeningBarPresentation
    let colour: Color
    private func step(_ id: String, symbol: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action:action) { Image(systemName:symbol).frame(width:24,height:28) }
            .disabled(!enabled).help(UXText.text(id)).accessibilityLabel(UXText.text(id))
            .accessibilityIdentifier(id)
    }
    var body: some View {
        VStack(spacing:0) {
            Divider()
            GeometryReader { geometry in
                HStack(spacing:8) {
                    Circle().fill(colour).frame(width:8,height:8).accessibilityHidden(true)
                    Text(presentation.speakerName).fontWeight(.semibold).lineLimit(1)
                        .frame(maxWidth:geometry.size.width*0.25,alignment:.leading)
                        .fixedSize(horizontal:true,vertical:false)
                        .help(presentation.speakerName)
                    Text(presentation.label).foregroundStyle(CassiniTheme.secondaryInk).monospacedDigit().fixedSize()
                        .accessibilityIdentifier("listen-turn")
                    if geometry.size.width >= 720 {
                        (Text(presentation.previousExcerpt).foregroundColor(CassiniTheme.secondaryColor)
                         + Text(presentation.previousExcerpt.isEmpty ? "" : " | ").foregroundColor(CassiniTheme.secondaryColor)
                         + Text(presentation.currentExcerpt))
                            .lineLimit(1).truncationMode(.tail).help([presentation.previousExcerpt,presentation.currentExcerpt].filter { !$0.isEmpty }.joined(separator:" | "))
                            .frame(maxWidth:.infinity,alignment:.leading).accessibilityIdentifier("listen-excerpt")
                    } else { Spacer(minLength:0) }
                    step("listen.previousTurn",symbol:"chevron.up",enabled:model.canStepListeningTurn(-1)) { model.stepListeningTurn(-1) }
                    step("listen.nextTurn",symbol:"chevron.down",enabled:model.canStepListeningTurn(1)) { model.stepListeningTurn(1) }
                    Divider().frame(height:18)
                    step("listen.previousSpeaker",symbol:"chevron.left",enabled:model.canStepListeningSpeaker(-1)) { model.stepListeningSpeaker(-1) }
                    step("listen.nextSpeaker",symbol:"chevron.right",enabled:model.canStepListeningSpeaker(1)) { model.stepListeningSpeaker(1) }
                    if model.listen.finished {
                        Button(UXText.text("listen.again")) { model.playListeningAgain() }
                            .fixedSize().accessibilityIdentifier("listen-again")
                    }
                    // Name… / Merge into… remain absent until the M4 naming sheet exists.
                    Button { model.stopListening() } label: { Image(systemName:"xmark").frame(width:24,height:28) }
                        .help(UXText.text("listen.stop")).accessibilityLabel(UXText.text("listen.stop"))
                        .accessibilityIdentifier("listen-stop")
                }.padding(.horizontal,16).frame(height:36)
            }.frame(height:36)
        }.font(.system(size:11.5)).buttonStyle(.borderless).background(.bar)
            .accessibilityElement(children:.contain).accessibilityLabel(presentation.accessibilityLabel)
            .accessibilityIdentifier("listening-bar")
            .onAppear { model.resetListeningAnnouncement(); model.announceListeningTurn() }
            .onChange(of:model.listen.turn) { _,_ in model.announceListeningTurn() }
            .onDisappear { model.resetListeningAnnouncement() }
    }
}

struct ListeningMeetingFocusedKey: FocusedValueKey { typealias Value = MeetingDetailModel }
extension FocusedValues {
    var listeningMeeting: MeetingDetailModel? {
        get { self[ListeningMeetingFocusedKey.self] }
        set { self[ListeningMeetingFocusedKey.self] = newValue }
    }
}

/// Present only while keyboard focus is inside a transcript row. Native TextKit
/// responders provide the same action through AppCommands' responder fallback.
struct TranscriptPlayFocusedKey: FocusedValueKey { typealias Value = () -> Void }
extension FocusedValues {
    var playTranscriptTurn: (() -> Void)? {
        get { self[TranscriptPlayFocusedKey.self] }
        set { self[TranscriptPlayFocusedKey.self] = newValue }
    }
}
