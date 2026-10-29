// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import Observation
import CassiniLibrary

@MainActor enum RecordingPreferences {
    static var defaults: UserDefaults {
        #if DEBUG
        if let defaults = SettingsFixture.defaults { return defaults }
        if RecordingFixture.enabled, let id = LibraryLaunchContext.argument("-CassiniCaptureID") {
            return UserDefaults(suiteName: "com.codemyriad.cassini-mac.capture-fixture." + id)!
        }
        #endif
        return .standard
    }
    static var skipFirst: Bool { defaults.bool(forKey: "CassiniSkipRecordFirst") }
}

@MainActor @Observable final class RecordCoordinator {
    static let shared = RecordCoordinator()
    var showingFirst = false
    var openRecordingWhenReady = false
    var focusNotesWhenOpened = false
    private var parent = LibraryLaunchContext.current.root
    func request(parent: URL, showRecording: Bool = true) {
        let recorder = RecordingController.shared
        if RecordingOverview.active || RecordingOverview.starting { RecordingOverview.stop(); return }
        guard RecordingOverview.canStart else { return }
        self.parent = parent
        openRecordingWhenReady = showRecording
        recorder.prepareDiskInfo(parent: parent)
        if RecordingPreferences.skipFirst { begin() }
        else { showingFirst = true }
    }
    func requestFromAnywhere() {
        let recorder = RecordingController.shared
        if RecordingOverview.active || RecordingOverview.starting { RecordingOverview.stop(); return }
        guard RecordingOverview.canStart else { return }
        let introduction = !RecordingPreferences.skipFirst
        if introduction { MeetingNavigation.shared.openLibrary?(); NSApp.activate(ignoringOtherApps: true) }
        request(parent: LibraryLocationModel.shared.roots[0], showRecording: introduction)
    }
    func openCurrent(focusNotes: Bool = false) {
        guard let folder = RecordingOverview.directory else { return }
        focusNotesWhenOpened = focusNotes
        if let meeting = LibraryStore.shared.meetings.first(where: { $0.libraryKey == folder.lastPathComponent }) {
            MeetingNavigation.shared.open(meeting); NSApp.activate(ignoringOtherApps: true)
        } else {
            openRecordingWhenReady = true; LibraryStore.shared.refresh(affected:folder)
            MeetingNavigation.shared.openLibrary?(); NSApp.activate(ignoringOtherApps:true)
        }
    }
    func confirm() { showingFirst = false; DispatchQueue.main.async { self.begin() } }
    private func begin() {
        MeetingNavigation.shared.back()
        let parent = LibraryLocationModel.shared.roots[0]
        Task {
            #if DEBUG
            if RecordingFixture.enabled { await RecordingController.shared.start(parent:parent); return }
            #endif
            do { try await CaptureCollection.shared.record() } catch { /* Catalog failure banner owns presentation. */ }
        }
    }
}

struct RecordFirstView: View {
    @AppStorage("CassiniSkipRecordFirst",store:RecordingPreferences.defaults) private var skip = false
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text(UXText.text("recordFirst.title")).font(.system(size: 20, weight: .bold)).accessibilityAddTraits(.isHeader)
            if let line = RecordingController.shared.diskLine { Text(line).foregroundStyle(.orange) }
            VStack(alignment: .leading, spacing: 10) {
                Text(UXText.text("recordFirst.responsibility")).lineSpacing(5)
                Toggle(UXText.text("recordFirst.dontShowAgain"), isOn: $skip).toggleStyle(.checkbox).font(.system(size: 11.5)).foregroundStyle(.secondary)
            }.padding(16).frame(maxWidth: .infinity, alignment: .leading).background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 16) {
                Text(UXText.text("recordFirst.willRecord")).font(.system(size: 11.5, weight: .bold)).foregroundStyle(.secondary)
                source(icon: "mic.fill", title: "common.yourMicrophone", description: "recordFirst.mic.description", caption: "recordFirst.mic.caption")
                Divider()
                if CaptureCollection.shared.hasCalls {
                    source(icon:"macwindow",title:"common.theOthers",description:"whatIsRecorded.othersHeard.browserMixed.description",caption:nil)
                } else {
                    source(icon:"display",title:"recordFirst.sound.title",description:"recordFirst.sound.description",caption:"recordFirst.sound.caption")
                }
            }
            HStack(spacing: 10) {
                Spacer()
                Button(UXText.text("common.notNow")) { RecordCoordinator.shared.showingFirst = false }
                    .buttonStyle(.plain).padding(.horizontal, 18).frame(height: 36).background(LibraryTheme.chip, in: RoundedRectangle(cornerRadius: 6))
                    .keyboardShortcut(.cancelAction)
                Button { RecordCoordinator.shared.confirm() } label: {
                    HStack(spacing: 8) { Circle().fill(.white).frame(width: 9, height: 9); Text(UXText.text("recordFirst.start")).fontWeight(.semibold) }
                        .padding(.horizontal, 18).frame(height: 36).foregroundStyle(.white).background(LibraryTheme.red, in: RoundedRectangle(cornerRadius: 6))
                }.buttonStyle(.plain).keyboardShortcut(.defaultAction).accessibilityIdentifier("record-first-start")
            }.padding(.top, 8)
        }.font(.system(size: 13)).padding(28).frame(width: 520)
            .accessibilityElement(children: .contain).accessibilityLabel(UXText.text("recordFirst.title"))
    }
    private func source(icon: String, title: String, description: String, caption: String?) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon).frame(width: 36, height: 36).background(Color.secondary.opacity(0.07), in: Circle()).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(UXText.text(title)).fontWeight(.semibold)
                Text(UXText.text(description)).foregroundStyle(.secondary).lineSpacing(4).fixedSize(horizontal: false, vertical: true)
                if let caption { Text(UXText.text(caption)).font(.system(size: 11.5)).foregroundStyle(.secondary).lineSpacing(4).fixedSize(horizontal:false,vertical:true) }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct LiveRecordingPill: View {
    let started: Date
    let microphone: Float
    let output: Float
    var frozenMs: Int64? = nil
    var body: some View {
        TimelineView(.periodic(from: started, by: 1)) { timeline in
            HStack(spacing: 8) {
                Button { if frozenMs == nil { RecordCoordinator.shared.openCurrent() } } label: {
                    HStack(spacing:8) {
                        Circle().fill(LibraryTheme.red).frame(width:9,height:9)
                        Text(LibraryFormat.liveBadge(frozenMs ?? RecordingOverview.elapsedMs)).fontWeight(.semibold).monospacedDigit().foregroundStyle(LibraryTheme.red)
                    }
                }.buttonStyle(.plain).accessibilityIdentifier("recording-open-current")
                    .accessibilityLabel(UXText.text("hidden.status",["liveBig":LibraryFormat.liveBig(frozenMs ?? RecordingOverview.elapsedMs)]))
                    .accessibilityHint(UXText.text("hidden.openCassini"))
                VStack(spacing:4) {
                    meter(microphone,label:"common.yourMicrophone",silent:frozenMs != nil || RecordingOverview.microphoneSilent)
                    meter(output,label:"recordFirst.sound.title")
                }.frame(width:30)
                Button(UXText.text("common.stop")) { if frozenMs == nil { RecordingOverview.stop() } }
                    .buttonStyle(.plain).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white).padding(.horizontal, 10).frame(height: 26)
                    .background(LibraryTheme.red, in: RoundedRectangle(cornerRadius: 5)).accessibilityIdentifier("recording-stop")
            }.padding(.horizontal, 10).frame(height: 34).background(LibraryTheme.red.opacity(0.10), in: RoundedRectangle(cornerRadius: 6))
                .help(RecordingRuntime.shared.power.held ? UXText.text("recording.pill.noSleep") : "")
        }
    }
    private func meter(_ level: Float, label: String, silent: Bool = false) -> some View {
        GeometryReader { geometry in
            Capsule().fill(silent ? LibraryTheme.amber.opacity(0.2) : LibraryTheme.red.opacity(0.15))
                .overlay(alignment: .leading) { Capsule().fill(LibraryTheme.red.opacity(0.7)).frame(width: geometry.size.width * Double(max(0, min(1, level)))) }
        }.frame(height: 4).accessibilityRepresentation {
            ProgressView(value: Double(max(0, min(1, level))))
                .accessibilityLabel(UXText.text(label))
        }
    }
}
