// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import Observation
import CassiniLibrary

/// One optional value records both the answer and the future naming default.
/// Missing means unanswered; false is an explicit Not now or Settings choice.
@MainActor @Observable final class VoicePreferences {
    static let key = "CassiniRememberNamedVoices"
    static let shared: VoicePreferences = {
        var fallback: Bool?
        #if DEBUG
        // Existing screenshot/probe fixtures represent an already answered app.
        // Dedicated question tests opt into the real unanswered state.
        if ProcessInfo.processInfo.environment["CASSINI_HOSTED_SCREENSHOTS"] == "1",
           LibraryLaunchContext.argument("-CassiniAskVoices") != "YES" { fallback = false }
        #endif
        return VoicePreferences(defaults:RecordingPreferences.defaults,fallback:fallback)
    }()
    @ObservationIgnored private let defaults: UserDefaults
    private(set) var answer: Bool?
    init(defaults: UserDefaults, fallback: Bool? = nil) {
        self.defaults = defaults
        answer = defaults.object(forKey:Self.key) as? Bool ?? fallback
    }
    var remember: Bool {
        get { answer ?? false }
        set { defaults.set(newValue,forKey:Self.key); answer = newValue }
    }
    func choice(existing: Bool) -> SpeakerVoiceChoice { SpeakerVoiceChoice(existing:existing,enabled:remember) }
    func shouldAsk(speakerCount: Int) -> Bool { answer == nil && speakerCount > 1 }
}

/// Defer to an existing modal and re-evaluate when its observable owner closes.
/// No scan, model download or voice-store access is needed to ask this question.
struct VoicesQuestionPresentation: ViewModifier {
    @State private var preferences = VoicePreferences.shared
    @State private var presented = false
    private var candidate: String? {
        guard let detail = MeetingNavigation.shared.savedDetail,
              preferences.shouldAsk(speakerCount:detail.meeting.speakers.count),
              !MeetingNavigation.shared.loading, !LibrarySearchModel.shared.visible,
              MeetingRenameCoordinator.shared.presentation == nil,
              !MeetingExportCoordinator.shared.showing, !RecordingDetailsCoordinator.shared.showing,
              !RecordCoordinator.shared.showingFirst, CompanionSetup.shared.presenter == nil,
              !BulkZipExportCoordinator.shared.busy,
              !LibraryMoveCoordinator.shared.busy, !MeetingTrashCoordinator.shared.busy else { return nil }
        return detail.meeting.libraryKey
    }
    func body(content: Content) -> some View {
        content
            .onChange(of:candidate,initial:true) { _, meeting in presented = meeting != nil }
            .onDisappear { presented = false }
            .sheet(isPresented:$presented) {
                VoicesQuestionView { value in preferences.remember = value; presented = false }
                    .interactiveDismissDisabled()
            }
    }
}
struct VoicesQuestionView: View {
    var answer: (Bool) -> Void
    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            Image(systemName:"person.2").font(.system(size:30)).foregroundStyle(CassiniTheme.accent).accessibilityHidden(true)
            Text(UXText.text("voices.setup.title")).font(.system(size:17,weight:.bold))
            Text(UXText.text("voices.setup.body.desktop")).font(.system(size:13)).foregroundStyle(CassiniTheme.ink2)
                .fixedSize(horizontal:false,vertical:true)
            Text(UXText.text("voices.setup.kindness") + " " + UXText.text("voices.setup.changeLater.desktop"))
                .font(.system(size:12)).foregroundStyle(CassiniTheme.ink3).fixedSize(horizontal:false,vertical:true)
            HStack {
                Spacer()
                Button(UXText.text("common.notNow")) { answer(false) }.keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("voices-question-not-now")
                Button(UXText.text("voices.setup.enable")) { answer(true) }.keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("voices-question-enable")
            }.padding(.top,6)
        }.padding(24).frame(width:440).fixedSize(horizontal:false,vertical:true)
            .accessibilityIdentifier("voices-question")
    }
}

#if DEBUG
@MainActor enum VoicePreferencesSelfTest {
    static func run() {
        guard SettingsFixture.id != nil,
              ProcessInfo.processInfo.environment["CASSINI_LOCAL_WORKFLOW_TESTS"] == "1" || ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] == "true" else { exit(78) }
        let suite = "io.codemyriad.cassini.voice-preference-proof." + UUID().uuidString
        let defaults = UserDefaults(suiteName:suite)!
        defer { defaults.removePersistentDomain(forName:suite) }
        func check(_ value: Bool) { if !value { FileHandle.standardError.write(Data("Voice preference proof failed\n".utf8)); exit(1) } }
        let first = VoicePreferences(defaults:defaults)
        check(first.answer == nil && !first.remember)
        check(!first.shouldAsk(speakerCount:0) && !first.shouldAsk(speakerCount:1) && first.shouldAsk(speakerCount:2))
        first.remember = false
        let declined = VoicePreferences(defaults:defaults)
        check(declined.answer == false && !declined.shouldAsk(speakerCount:3) && !declined.choice(existing:false).remember)
        declined.remember = true
        let enabled = VoicePreferences(defaults:defaults)
        check(enabled.answer == true && !enabled.shouldAsk(speakerCount:3) && enabled.choice(existing:false).remember)
        check(enabled.choice(existing:false).update(prepared:false) == .preserve)
        check(enabled.choice(existing:false).update(prepared:true) == .enroll)
        enabled.remember = false
        let disabled = VoicePreferences(defaults:defaults)
        check(disabled.answer == false && !disabled.shouldAsk(speakerCount:3))
        check(disabled.choice(existing:true).remember && disabled.choice(existing:true).update(prepared:false) == .preserve)
        check(disabled.choice(existing:false).update(prepared:true) == .preserve)
        defaults.removePersistentDomain(forName:suite)
        FileHandle.standardOutput.write(Data("{\"questionOnlyForMultipleSpeakers\":true,\"notNowPersists\":true,\"enablePersists\":true,\"settingsChoicePersists\":true,\"existingVoicesPreserved\":true,\"missingPreparationPreserved\":true}\n".utf8))
        exit(0)
    }
}
#endif
