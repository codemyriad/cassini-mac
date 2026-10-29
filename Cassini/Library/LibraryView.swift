// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import CassiniLibrary

enum LibraryTheme {
    static let dim = adaptive(light: NSColor(red: 106/255, green: 106/255, blue: 112/255, alpha: 1), dark: .secondaryLabelColor)
    static let sidebar = Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .windowBackgroundColor : NSColor(red: 241/255, green: 240/255, blue: 245/255, alpha: 1) })
    static let chip = adaptive(light: NSColor(red: 239/255, green: 239/255, blue: 243/255, alpha: 1), dark: .controlBackgroundColor)
    static let amber = adaptive(light:NSColor(red:122/255,green:77/255,blue:0,alpha:1),dark:.systemOrange)
    static let amberTint = adaptive(light:NSColor(red:1,green:240/255,blue:199/255,alpha:1),dark:NSColor.systemOrange.withAlphaComponent(0.16))
    static let red = adaptive(light: NSColor(red: 215/255, green: 0, blue: 21/255, alpha: 1), dark: .systemRed)
    private static func adaptive(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light })
    }
}
struct LibraryView: View {
    @State private var search = LibrarySearchModel.shared
    @State private var exporter = MeetingExportCoordinator.shared
    @State private var store = LibraryStore.shared
    @State private var sessionPlayback = SessionPlaybackController()
    @State private var navigation = MeetingNavigation.shared
    @State private var toolbarWidth: CGFloat = 1120
    @State private var recordCoordinator = RecordCoordinator.shared
    @State private var recorder = RecordingController.shared
    @State private var companionSetup = CompanionSetup.shared
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        GeometryReader { geometry in
            Group {
                if let detail = navigation.detail {
                    if detail.meeting.state.lifecycle != .saved { RecordingPageView(detail:detail,format:store.format) }
                    else { MeetingView(model:detail,format:store.format) }
                }
                else if navigation.loading { ProgressView() }
                else if search.visible { LibrarySearchView(format:store.format) }
                else if store.loaded && store.meetings.isEmpty && !store.offline { firstRun }
                else { split }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
                .onAppear { toolbarWidth = geometry.size.width }
                .onChange(of: geometry.size.width) { _, width in toolbarWidth = width }
        }
        .font(.system(size: 13))
        .safeAreaInset(edge:.top,spacing:0) { CaptureFailureBanner() }
        .frame(minWidth: 760, minHeight: 480)
        .navigationTitle(navigation.detail?.meeting.title ?? UXText.text("library.title"))
        .toolbar(removing: .title)
        .toolbar {
            if let detail = navigation.detail, detail.meeting.state.lifecycle != .saved {
                ToolbarItem(placement:.navigation) {
                    Button { navigation.back() } label: { Image(systemName:"chevron.left").frame(width:28,height:30) }
                        .help(UXText.text("common.backToLibrary")).accessibilityLabel(UXText.text("common.backToLibrary")).accessibilityIdentifier("recording-back")
                }
                ToolbarItem(placement:.navigation) {
                    if RecordingOverview.active, let started = RecordingOverview.startedAt {
                        LiveRecordingPill(started:started,microphone:RecordingOverview.levels["microphone",default:0],output:RecordingOverview.levels["output",default:0])
                    } else if store.context.screenshot {
                        LiveRecordingPill(started:store.context.now ?? Date(),microphone:0,output:0.58,frozenMs:detail.meeting.state.liveMs)
                    } else { ProgressView().controlSize(.small) }
                }
                ToolbarItem(placement:.principal) {
                    Text(detail.meeting.title ?? UXText.text("library.untitled")).font(.system(size:13,weight:.bold)).lineLimit(1)
                        .accessibilityIdentifier("recording-header-title")
                }
            } else if let detail = navigation.detail {
                ToolbarItem(placement: .navigation) {
                    HStack(spacing: 0) {
                        HStack(spacing: 12) {
                            Button { navigation.back() } label: { Image(systemName: "chevron.left").frame(width: 28, height: 30) }
                                .help(UXText.text("common.backToLibrary")).accessibilityLabel(UXText.text("common.backToLibrary"))
                                .accessibilityIdentifier("meeting-back")
                            Spacer(minLength: 0)
                            if RecordingOverview.active { Button(UXText.text("common.stop")) { RecordingOverview.stop() } }
                            else { recordButton(big: false) }
                        }.frame(width: 169)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(detail.meeting.title ?? UXText.text("library.untitled")).font(.system(size: 13, weight: .bold))
                                .lineLimit(1).accessibilityIdentifier("meeting-title")
                            if let start = detail.meeting.start {
                                Text(store.format.previewSubtitle(start, durationMs: detail.meeting.durationMs, received: detail.meeting.state.origin == .received))
                                    .font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1).accessibilityIdentifier("meeting-subtitle")
                            }
                        }.padding(.leading, 16).frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityElement(children: .contain)
                        HStack(spacing: 14) {
                            if detail.meeting.canWriteDown && detail.meeting.state.transcript == .none {
                                Button(UXText.text("common.writeDown")) { TranscriptionQueue.shared.writeDown(detail) }
                                    .buttonStyle(.bordered).disabled(LibraryMoveCoordinator.shared.busy).accessibilityIdentifier("meeting-write-down")
                            }
                            Button(UXText.text("common.exportEllipsis")) { exporter.show(detail.meeting) }.buttonStyle(.plain).fontWeight(.semibold)
                                .padding(.horizontal, 14).frame(height: 34).background(LibraryTheme.chip, in: RoundedRectangle(cornerRadius: 6)).disabled(!MeetingExportCoordinator.canExport(detail.meeting)).accessibilityIdentifier("meeting-export")
                            Button {} label: { Image(systemName: "ellipsis").frame(width: 28, height: 30) }.buttonStyle(.plain)
                                .disabled(true).accessibilityLabel(UXText.text("meeting.moreActions"))
                        }
                    }.frame(width: max(480, toolbarWidth - 110))
                }
            } else {
            ToolbarItem(placement: .navigation) {
                HStack(spacing: 0) {
                    toolbarControl.frame(width: search.visible ? 388 : store.meetings.isEmpty ? nil : 328, alignment: .leading)
                    if search.visible || !store.meetings.isEmpty { toolbarTitle }
                }
            }
            if store.meetings.isEmpty && !search.visible {
                ToolbarItem(placement: .principal) { toolbarTitle }
            }
            }
        }
        .toolbar {
            if !search.visible && navigation.detail == nil && !store.meetings.isEmpty {
                ToolbarItem(placement:.primaryAction) {
                    LibrarySearchField(text:$search.query,onChange:{ search.open() },onCancel:{ search.close() }).frame(width:180)
                }
            }
        }
        .background(WindowAccessor { window in
            guard let window else { return }
            window.setAccessibilityIdentifier("cassini-library-window")
            window.toolbarStyle = .unified
            window.titleVisibility = .hidden
            RecordingConfirmation.attach(to: window)
            #if DEBUG
            if store.loaded { ScreenshotFixture.prepareLibrary(window) }
            #endif
        })
        .sheet(isPresented:$exporter.showing) { if let meeting = exporter.meeting { MeetingExportSheet(meeting:meeting) } }
        .sheet(isPresented: $recordCoordinator.showingFirst) { RecordFirstView() }
        .sheet(isPresented:Binding(get:{ companionSetup.presenter == .library },set:{ if !$0 { companionSetup.close() } })) { CompanionSetupView() }
        .onAppear {
            SettingsNavigation.shared.open = { openSettings(); NSApp.activate(ignoringOtherApps:true) }
            search.update(store.meetings)
            sessionPlayback.onFailure = { NSApp.presentError($0) }
            let open = openWindow
            LegacyOpening.handler = { url in open(id: "legacy-viewer", value: LegacyRoute(url: url)) }
            navigation.openLibrary = { open(id: "library") }
            store.start()
        }
        .onDisappear { sessionPlayback.stop(); navigation.back(); search.close() }
        .onChange(of: recorder.isSaving) { _,saving in
            if saving, let folder = recorder.directory { navigation.captureBeganSaving(at:folder) }
        }
        .onChange(of: store.selectedKey) { _, _ in sessionPlayback.stop() }
        .onChange(of: store.revision) { _, _ in
            search.update(store.meetings)
            sessionPlayback.reconcile(store.selected, offline: store.offline)
            navigation.update(store.meetings, offline: store.offline)
            if recordCoordinator.openRecordingWhenReady, RecordingOverview.active,
               let current = store.meetings.first(where: { $0.libraryKey == RecordingOverview.directory?.lastPathComponent }) {
                recordCoordinator.openRecordingWhenReady = false; navigation.open(current)
            }
            #if DEBUG
            if store.context.screenshot, LibraryLaunchContext.argument("-CassiniScreenshot") == "recording", navigation.detail == nil,
               let meeting = store.meetings.first(where: { $0.state.lifecycle == .recording }) { navigation.open(meeting, frozen:true) }
            #endif
            #if DEBUG
            if store.context.screenshot, LibraryLaunchContext.argument("-CassiniScreenshot") == "search", !search.visible {
                search.query = "budget"; search.speaker = "Marta"; search.open()
            }
            if store.context.screenshot, LibraryLaunchContext.argument("-CassiniScreenshot") == "record-first", !recordCoordinator.showingFirst {
                recordCoordinator.showingFirst = true
            }
            if store.context.screenshot, ["meeting","export"].contains(LibraryLaunchContext.argument("-CassiniScreenshot") ?? ""), navigation.detail == nil,
               let meeting = store.meetings.first(where: { $0.title == (LibraryLaunchContext.argument("-CassiniScreenshot") == "export" ? "Budget review" : "Client call, Rossi & Partners") }) {
                navigation.open(meeting,frozen:true)
                if LibraryLaunchContext.argument("-CassiniScreenshot") == "export" {
                    Task { @MainActor in
                        try? await Task.sleep(for:.milliseconds(300)); exporter.show(meeting)
                    }
                }
            }
            #endif
        }
        .onOpenURL { LegacyOpening.openDocument($0) }
        .dropDestination(for:URL.self) { urls,_ in
            let audio = urls.filter { $0.isFileURL && ["opus","ogg"].contains($0.pathExtension.lowercased()) }
            audio.forEach { LibraryImportCoordinator.shared.open($0) }; return !audio.isEmpty
        }
        .preferredColorScheme(store.context.screenshot ? .light : nil)
    }
    private var toolbarTitle: some View {
        Text(UXText.text(search.visible ? "search.title" : "library.title")).font(.system(size: 15, weight: .bold))
            .accessibilityAddTraits(.isHeader).accessibilityIdentifier("library-toolbar-title")
    }
    private var split: some View {
        HStack(spacing: 0) {
            List(selection: $store.selectedKey) {
                ForEach(store.groups, id: \.title) { group in
                    Section {
                        ForEach(group.meetings, id: \.libraryKey) { meeting in
                            row(meeting).tag(meeting.libraryKey)
                                .simultaneousGesture(TapGesture().onEnded { store.selectedKey = meeting.libraryKey })
                                .onTapGesture(count:2) { if meeting.state.lifecycle != .saved { navigation.open(meeting) } }
                                .listRowSeparator(.hidden)
                                .listRowBackground(RoundedRectangle(cornerRadius: 7)
                                    .fill(store.selectedKey == meeting.libraryKey ? Color.accentColor : Color.clear)
                                    .padding(.horizontal, 8))
                                .listRowInsets(EdgeInsets(top: 8, leading: 10, bottom: 8, trailing: 10))
                                .accessibilityIdentifier("meeting-" + meeting.libraryKey)
                        }
                    } header: {
                        Text(group.title).font(.system(size: 11.5, weight: .bold)).foregroundStyle(LibraryTheme.dim).textCase(nil)
                    }
                }
                if !store.meetings.isEmpty, store.meetings.allSatisfy({ $0.state.origin == .received }) {
                    Text(UXText.text("received.libraryHint")).font(.system(size:11.5)).foregroundStyle(LibraryTheme.dim)
                        .listRowBackground(Color.clear).listRowSeparator(.hidden)
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .background(LibraryTheme.sidebar)
            .frame(minWidth: 400, maxWidth: 400)
            .accessibilityLabel(UXText.text("library.listPane.a11y"))
            Divider()
            if let meeting = store.selected { preview(meeting) }
            else { Color(nsColor: .textBackgroundColor) }
        }
    }
    private var toolbarControl: some View {
        Group {
            if RecordingOverview.active, let started = RecordingOverview.startedAt {
                LiveRecordingPill(started: started, microphone: RecordingOverview.levels["microphone", default: 0], output: RecordingOverview.levels["output", default: 0])
            } else if RecordingOverview.saving {
                HStack { ProgressView().controlSize(.small); Text(UXText.text("states.badge.saving")) }.frame(height: 34)
            } else if let live = store.meetings.first(where: { $0.state.lifecycle == .recording }) {
                // Read-only header placeholder until UX5 owns transport/levels.
                HStack(spacing: 8) {
                    Circle().fill(LibraryTheme.red).frame(width: 10, height: 10)
                    Text(LibraryFormat.liveBadge(live.state.liveMs ?? 0)).fontWeight(.semibold).monospacedDigit().foregroundStyle(LibraryTheme.red)
                    VStack(spacing: 3) {
                        Capsule().fill(LibraryTheme.red.opacity(0.6)).frame(width: 30, height: 4)
                        Capsule().fill(LibraryTheme.red.opacity(0.3)).frame(width: 30, height: 4)
                    }.accessibilityHidden(true)
                    Text(UXText.text("common.stop")).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 10).frame(height: 26).background(LibraryTheme.red, in: RoundedRectangle(cornerRadius: 5))
                }.fixedSize().padding(.horizontal, 10).frame(height: 34).background(LibraryTheme.red.opacity(0.10), in: RoundedRectangle(cornerRadius: 6))
            } else { recordButton(big: false) }
        }
    }
    private func row(_ meeting: LibraryMeeting) -> some View {
        let selected = store.selectedKey == meeting.libraryKey
        let dim = selected ? Color.white.opacity(0.86) : LibraryTheme.dim
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text(meeting.title ?? UXText.text("library.untitled")).fontWeight(.semibold).lineLimit(1)
                Spacer(minLength: 2)
                if let start = meeting.start { Text(store.format.rowTime(start)).font(.system(size: 11.5)).foregroundStyle(dim).monospacedDigit() }
            }
            HStack(spacing: 6) {
                if let badge = meeting.state.badge { badgePill(badge, selected: selected) }
                if let meta = rowMeta(meeting) { Text(meta).foregroundStyle(dim).lineLimit(1) }
            }.font(.system(size: 11.5))
            if let line = rowSecondLine(meeting) { Text(line).font(.system(size: 11.5)).foregroundStyle(dim).lineLimit(1) }
        }
        .foregroundStyle(selected ? .white : Color(nsColor: .labelColor))
        .padding(.vertical, 1).frame(minHeight: 50, alignment: .top)
    }
    // R11: visible badge precedence also governs both row text lines.
    private func rowMeta(_ meeting: LibraryMeeting) -> String? {
        switch meeting.state.badge?.kind {
        case "recording": return meeting.isBrowserCapture ? UXText.text("common.listeningInsideBrowser") : nil
        case "saving", "transcribing": return nil
        default: return LibraryFormat.rowMeta(durationMs: meeting.durationMs, names: meeting.speakerNames)
        }
    }
    private func rowSecondLine(_ meeting: LibraryMeeting) -> String? {
        switch meeting.state.badge?.kind {
        case "recording": return meeting.isBrowserCapture ? UXText.text("library.row.recording.line") : nil
        case "saving": return nil
        case "transcribing": return meeting.durationMs.map { UXText.text("library.row.transcribing.line", ["duration": LibraryFormat.meetingDuration($0)]) }
        default: return meeting.quote?.displayText
        }
    }
    private func badgePill(_ badge: MeetingBadge, selected: Bool) -> some View {
        let tint: Color = badge.tint == "red" ? LibraryTheme.red : badge.tint == "amber" ? Color(red: 122/255, green: 77/255, blue: 0) : badge.tint == "accent" ? .accentColor : LibraryTheme.dim
        return HStack(spacing: 4) {
            if badge.dot == true { Circle().fill(selected ? .white : tint).frame(width: 5, height: 5) }
            Text(badge.text).fontWeight(.semibold)
        }.padding(.horizontal, 7).padding(.vertical, 1)
            .foregroundStyle(selected ? .white : tint)
            .background((selected ? Color.white.opacity(0.22) : tint.opacity(0.10)), in: Capsule())
    }
    private func preview(_ meeting: LibraryMeeting) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(meeting.title ?? UXText.text("library.untitled")).font(.system(size: 22, weight: .bold)).accessibilityAddTraits(.isHeader)
                    if let start = meeting.start { Text(store.format.previewSubtitle(start, durationMs: meeting.durationMs, received: meeting.state.origin == .received)).foregroundStyle(LibraryTheme.dim).accessibilityIdentifier("preview-subtitle") }
                }
                if let line = RecordingOverview.diskLine { Text(line).foregroundStyle(.orange) }
                if meeting.state.transcript == .failed { InlineMeetingLine(id: "errors.transcribeFailed.line", actionID: "common.tryAgain", action: { TranscriptionQueue.shared.enqueue(meeting, retry: true) }).disabled(LibraryMoveCoordinator.shared.busy) }
                if meeting.state.transcript == .damaged { InlineMeetingLine(id: "errors.transcriptDamaged.line", action: nil) }
                if let folder = meeting.received?.originalFolderName {
                    HStack(alignment:.top,spacing:12) {
                        Image(systemName:"folder").padding(.top,2).accessibilityHidden(true)
                        Text(UXText.text("received.folderCard",["folder":folder])).fixedSize(horizontal:false,vertical:true)
                    }.padding(16).frame(maxWidth:.infinity,alignment:.leading)
                        .background(LibraryTheme.chip,in:RoundedRectangle(cornerRadius:8)).accessibilityIdentifier("received-folder-card")
                }
                if meeting.state.origin == .own { ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(meeting.speakers, id: \.id) { speaker in
                            HStack(spacing: 6) {
                                Text(speaker.displayName)
                                if speaker.provenance == .recognised { autoTag }
                            }.fixedSize().padding(.horizontal, 12).frame(height: 28).background(LibraryTheme.chip, in: Capsule())
                        }
                    }
                }.scrollIndicators(.hidden) }
                HStack(spacing: 10) {
                    Button { play(meeting) } label: { Label(UXText.text(sessionPlayback.isPlaying ? "player.pause" : "common.play"), systemImage: sessionPlayback.isPlaying ? "pause.fill" : "play.fill").fontWeight(.semibold).padding(.horizontal, 16).frame(height: 36) }
                        .buttonStyle(.plain).foregroundStyle(.white).background(Color.accentColor, in: RoundedRectangle(cornerRadius: 6))
                        .opacity(!sessionPlayback.isPlaying && (!(meeting.canPlaySession || meeting.state.origin == .received && !meeting.audioFiles.isEmpty) || sessionPlayback.isPreparing) ? 0.45 : 1)
                        .disabled(LibraryMoveCoordinator.shared.busy || !sessionPlayback.isPlaying && (!(meeting.canPlaySession || meeting.state.origin == .received && !meeting.audioFiles.isEmpty) || sessionPlayback.isPreparing))
                        .accessibilityIdentifier("preview-play")
                if meeting.canWriteDown && meeting.state.transcript == .none && !meeting.metadataReadOnly {
                    Button(UXText.text("common.writeDown")) { TranscriptionQueue.shared.enqueue(meeting) }
                        .buttonStyle(.bordered).disabled(LibraryMoveCoordinator.shared.busy).accessibilityIdentifier("preview-write-down")
                }

                    Button { readTranscript(meeting) } label: {
                        Text(UXText.text("library.preview.readTranscript")).fontWeight(.semibold).padding(.horizontal, 16).frame(height: 36)
                    }.buttonStyle(.plain).background(LibraryTheme.chip, in: RoundedRectangle(cornerRadius: 6))
                        .disabled(meeting.transcriptItems.isEmpty || LibraryMoveCoordinator.shared.busy)
                        .accessibilityIdentifier("preview-read-transcript")
                }
                if !meeting.transcriptItems.isEmpty {
                    VStack(alignment: .leading, spacing: 16) {
                        Divider()
                        Text(UXText.text("library.preview.transcriptHeading")).font(.system(size: 11.5, weight: .bold)).foregroundStyle(LibraryTheme.dim).padding(.top, 4)
                        ForEach(Array(store.excerpt(meeting).enumerated()), id: \.offset) { _, turn in
                            HStack(alignment: .top, spacing: 16) {
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack(spacing: 5) {
                                        Text(meeting.speakers.first { $0.id == turn.speaker }?.displayName ?? UXText.text("common.speaker.unnamed", ["n": "1"])).fontWeight(.semibold)
                                        if meeting.speakers.first(where: { $0.id == turn.speaker })?.provenance == .recognised { autoTag }
                                    }
                                    Text(LibraryFormat.position(turn.startMs)).font(.system(size: 11.5)).foregroundStyle(LibraryTheme.dim).monospacedDigit()
                                }.frame(width: 110, alignment: .leading)
                                Text(turn.text).lineSpacing(4).fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                }
            }.padding(.horizontal, 44).padding(.vertical, 32)
        }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color(nsColor: .textBackgroundColor))
            .accessibilityElement(children: .contain)
            .accessibilityLabel(UXText.text("library.previewPane.a11y"))
    }
    private var autoTag: some View {
        Text(UXText.text("common.autoTag")).font(.system(size: 10, weight: .medium)).foregroundStyle(LibraryTheme.dim)
            .padding(.horizontal, 4).overlay(RoundedRectangle(cornerRadius: 4).stroke(LibraryTheme.dim.opacity(0.3)))
            .help(UXText.text("common.autoTag.tooltip"))
    }
    private var firstRun: some View {
        VStack(spacing: 0) {
            Spacer()
            VStack(spacing: 22) {
                Image(systemName: "mic").font(.system(size: 36, weight: .light)).foregroundStyle(LibraryTheme.dim)
                    .frame(width: 96, height: 96).background(LibraryTheme.chip, in: Circle()).accessibilityHidden(true)
                VStack(spacing: 8) {
                    Text(UXText.text("firstRun.title")).font(.system(size: 22, weight: .bold)).fixedSize(horizontal: true, vertical: false)
                    Text(UXText.text("firstRun.body")).foregroundStyle(LibraryTheme.dim).lineSpacing(4).multilineTextAlignment(.center).frame(maxWidth: 460)
                }
                if let line = RecordingOverview.diskLine { Text(line).foregroundStyle(.orange) }
                recordButton(big: true)
                Text(UXText.text("firstRun.shortcutHint", ["shortcut": RecordingRuntime.shared.shortcut.choice.glyph])).font(.system(size: 11.5)).foregroundStyle(LibraryTheme.dim)
            }
            Spacer()
            HStack(spacing: 8) {
                Image(systemName: "lock").accessibilityHidden(true)
                if LibraryLocationModel.shared.location.primaryPath == LibraryLocation.standardRoot.path || store.context.screenshot {
                    Text(UXText.text("firstRun.footer"))
                } else {
                    Text(UXText.text("settings.library.folder.title") + ": " + LibraryLocationModel.shared.displayPath)
                }
            }.font(.system(size: 11.5)).foregroundStyle(LibraryTheme.dim).padding(16)
        }.frame(maxWidth: .infinity, maxHeight: .infinity).background(Color(nsColor: .textBackgroundColor))
    }
    private func recordButton(big: Bool) -> some View {
        Button { sessionPlayback.stop(); RecordCoordinator.shared.request(parent: store.context.root) } label: {
            HStack(spacing: big ? 10 : 8) {
                Circle().fill(big ? Color.white : LibraryTheme.red).frame(width: big ? 12 : 10, height: big ? 12 : 10)
                Text(UXText.text("common.record")).fontWeight(.semibold)
            }.padding(.horizontal, big ? 22 : 14).frame(height: big ? 44 : 34)
                .foregroundStyle(big ? .white : Color(nsColor: .labelColor))
                .background(big ? LibraryTheme.red : LibraryTheme.chip, in: RoundedRectangle(cornerRadius: big ? 22 : 6))
        }.buttonStyle(.plain).disabled(!RecordingOverview.canStart).accessibilityIdentifier(big ? "first-run-record" : "toolbar-record")
    }
    private func play(_ meeting: LibraryMeeting) {
        if meeting.state.origin == .own { if !sessionPlayback.isPlaying { PlayerController.pauseActive() }; sessionPlayback.toggle(meeting); return }
        guard !meeting.audioFiles.isEmpty else { return }
        navigation.open(meeting, autoplay: true)
    }
    private func readTranscript(_ meeting: LibraryMeeting) {
        sessionPlayback.stop(); navigation.open(meeting)
    }
}
