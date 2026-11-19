// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import CassiniLibrary

struct LibraryView: View {
    @State private var search = LibrarySearchModel.shared
    @State private var trash = MeetingTrashCoordinator.shared
    @Environment(\.undoManager) private var undoManager
    @State private var exporter = MeetingExportCoordinator.shared
    @State private var bulkExporter = BulkZipExportCoordinator.shared
    @State private var recordingDetails = RecordingDetailsCoordinator.shared
    @State private var store = LibraryStore.shared
    @State private var sessionPlayback = SessionPlaybackController()
    @State private var navigation = MeetingNavigation.shared
    #if DEBUG
    @State private var searchFixturePrepared = false
    @State private var screenshotTestSheet = false
    #endif
    @State private var toolbarWidth: CGFloat = 1120
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var sidebarSearchPresented = false
    @State private var sidebarWidth: CGFloat = 340
    @State private var recordCoordinator = RecordCoordinator.shared
    @State private var recorder = RecordingController.shared
    @State private var captures = CaptureCollection.shared
    @State private var companionSetup = CompanionSetup.shared
    @State private var rename = MeetingRenameCoordinator.shared
    @State private var updates = ApplicationUpdates.shared
    @State private var speechModels = SpeechModelController.shared
    @State private var transcriptionQueue = TranscriptionQueue.shared
    @State private var importer = LibraryImportCoordinator.shared
    @State private var dropState: LibraryDropState = .idle
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow
    private var showsFirstRun: Bool {
        store.loaded && store.meetings.isEmpty && importer.transientItems.isEmpty && !store.offline
    }
    private var showsSplit: Bool { !navigation.loading && !search.visible && !showsFirstRun }
    private var recordingSelected: Bool {
        store.selected.map { $0.state.lifecycle != .saved } == true && !search.visible && !showsFirstRun
    }
    var body: some View {
        GeometryReader { geometry in
            Group {
                if navigation.loading { ProgressView() }
                else if search.visible { LibrarySearchView(format:store.format) }
                else if showsFirstRun { firstRun }
                else { split }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
                .onAppear { toolbarWidth = geometry.size.width }
                .onChange(of: geometry.size.width) { _, width in toolbarWidth = width }
        }
        .modifier(VoicesQuestionPresentation())
        .font(.system(size: 13))
        .safeAreaInset(edge:.bottom,spacing:0) {
            UpdateReadyFooter(updates:updates)
        }
        .safeAreaInset(edge:.top,spacing:0) {
            CaptureFailureBanner(); trashFailure
            VStack(alignment:.leading,spacing:0) {
                ParakeetRecommendationView(afterFirst:true)
                ParakeetDefaultNotice()
            }.padding(.horizontal,18).background(showsFirstRun ? CassiniTheme.surface : CassiniTheme.paneGround)

            if !store.context.screenshot && companionSetup.showLibraryState && showsSplit && !search.visible {
                BrowserConnectionStateView(identifier:"library-browser-status",presenter:.library)
                    .font(.system(size:11.5)).foregroundStyle(CassiniTheme.ink2).padding(.horizontal,18).padding(.vertical,8)
                    .background(CassiniTheme.paneGround)
            }
        }

        .task { await speechModels.refresh() }
        .onChange(of:scenePhase) { _, phase in
            if phase == .active { Task { await speechModels.refreshRecommendation() } }
        }
        .onChange(of: search.sidebarFocusRequest) { _, _ in
            columnVisibility = .all
            sidebarSearchPresented = true
        }
        .onChange(of: search.query) { _, query in
            if !query.isEmpty && !search.visible {
                search.open()
            }
        }
        .onChange(of: sidebarSearchPresented) { _, presented in
            if presented && !search.visible {
                sidebarSearchPresented = false
                search.open()
            }
        }
        .frame(minWidth: showsFirstRun ? 560 : nil, minHeight: 480)
        .modifier(LibraryWindowTitleModifier(
            savedDetail: navigation.savedDetail,
            showsFirstRun: showsFirstRun,
            searchVisible: search.visible,
            format: store.format,
            canRename: navigation.savedDetail.map { rename.canRename($0.meeting) } ?? false,
            onRename: { detail, newTitle in rename.renameInline(detail.meeting, to: newTitle) }
        ))
        .toolbar {
            if showsFirstRun && !search.visible {
                ToolbarItem(placement:.automatic) { Spacer() }
                ToolbarItem(id:"first-run-actions",placement:.primaryAction) { toolbarControl }
            } else if search.visible {
                ToolbarItem(placement: .navigation) {
                    HStack(spacing: 0) {
                        toolbarControl
                            .padding(.trailing,10)
                            .frame(width: 388, alignment: .trailing)
                        toolbarTitle
                    }
                }
            }
        }
        .modifier(ConditionalFirstRunToolbarChrome(enabled: showsFirstRun && !search.visible))
        .background(WindowAccessor { window in
            guard let window else { return }
            window.setAccessibilityIdentifier("cassini-library-window")
            window.backgroundColor = showsFirstRun ? NSColor(CassiniTheme.surface) : .windowBackgroundColor
            ScrollEdgeChrome.configureUnifiedWindow(window)
            window.titleVisibility = .hidden
            RecordingConfirmation.attach(to: window)
            SpeakerEditorChrome.update(window,visible:rename.presentation == .speakers)
            #if DEBUG
            if store.loaded { ScreenshotFixture.prepareLibrary(window) }
            #endif
        })
        .disabled(rename.presentation == .speakers)
        .accessibilityHidden(rename.presentation == .speakers)
        .overlay {
            if rename.presentation == .speakers {
                ZStack {
                    CassiniTheme.scrim.ignoresSafeArea().contentShape(Rectangle())
                    GeometryReader { geometry in
                        ScrollView {
                            SpeakerEditorView().padding(24)
                                .frame(maxWidth:.infinity)
                                .frame(minHeight:geometry.size.height)
                        }
                    }
                }
            }
        }
         .sheet(isPresented:Binding(get:{ rename.presentation == .sheet },set:{ if !$0 { rename.cancel() } })) {
            MeetingRenameView()
        }
        .sheet(isPresented:$exporter.showing) { if let meeting = exporter.meeting { MeetingExportSheet(meeting:meeting) } }
        .sheet(isPresented:$recordingDetails.showing) { RecordingDetailsSheet() }
        .overlay(alignment:.bottom) { MeetingExportNotice() }
        .overlay(alignment:.bottom) { SpeakerEditFailureNotice() }
        #if DEBUG
        .overlay(alignment:.topLeading) {
            if RecordingFixture.enabled {
                Text(CaptureNotifications.savedFixtureTitles.joined(separator:"\n")).font(.system(size:1))
                    .frame(width:1,height:1).opacity(0.01).accessibilityIdentifier("recording-notification-fixture")
            }
        }
        #endif
        .sheet(isPresented: $recordCoordinator.showingFirst) { RecordFirstView() }
        #if DEBUG
        .sheet(isPresented: $screenshotTestSheet) { TestRecordingView() }
        #endif
        .sheet(isPresented:Binding(get:{ companionSetup.presenter == .library },set:{ if !$0 { companionSetup.close() } })) { CompanionSetupView() }
        .onAppear {
            search.update(store.meetings)
            sessionPlayback.onFailure = { NSApp.presentError($0) }
            store.start()
            if navigation.detail == nil { openSelection() }
        }
        .onDisappear { rename.cancel(); sessionPlayback.stop(); navigation.back(); search.close() }
        .onChange(of: recorder.isSaving) { _,saving in
            if saving, let folder = recorder.directory { navigation.captureBeganSaving(at:folder) }
        }
        .onChange(of: search.visible) { _, visible in
            if !visible, navigation.detail == nil { openSelection() }
        }
        .onReceive(NotificationCenter.default.publisher(for: MeetingNavigation.returnToLibrarySelection)) { _ in
            openSelection(userInitiated: true)
        }
        .onChange(of: store.selectedKeys) { _, _ in
            sessionPlayback.stop()
            openSelection()
        }
        .onChange(of: store.revision) { _, _ in
            search.update(store.meetings)
            if !store.offline { RecordingPageModel.reconcile(store.meetings) }
            sessionPlayback.reconcile(store.selected, offline: store.offline)
            navigation.update(store.meetings, offline: store.offline)
            if navigation.detail == nil { openSelection() }
            if recordCoordinator.openRecordingWhenReady, RecordingOverview.active,
               let current = store.meetings.first(where: { $0.libraryKey == RecordingOverview.directory?.lastPathComponent }) {
                recordCoordinator.openRecordingWhenReady = false; navigation.open(current)
            }
            #if DEBUG
            if store.context.screenshot, LibraryLaunchContext.argument("-CassiniScreenshot") == "recording", navigation.detail == nil,
               let meeting = store.meetings.first(where: { $0.state.lifecycle == .recording }) { navigation.open(meeting, frozen:true) }
            #endif
            #if DEBUG
            if store.context.screenshot, LibraryLaunchContext.argument("-CassiniScreenshot") == "search", !searchFixturePrepared {
                searchFixturePrepared = true
                search.query = "budget"; search.speaker = "Marta"; search.open()
            }
            if store.context.screenshot, LibraryLaunchContext.argument("-CassiniScreenshot") == "record-first", !recordCoordinator.showingFirst {
                recordCoordinator.showingFirst = true
            }
            if store.context.screenshot, LibraryLaunchContext.argument("-CassiniScreenshot") == "test-recording-testing", !screenshotTestSheet {
                TestRecordingController.shared.freezeForScreenshot(phase: .recording, elapsedMs: 3_000, heard: [.me], levels: [.me: 0.42, .others: 0])
                screenshotTestSheet = true
            }
            if store.context.screenshot, LibraryLaunchContext.argument("-CassiniScreenshot") == "test-recording-result", !screenshotTestSheet {
                TestRecordingController.shared.freezeForScreenshot(phase: .result, elapsedMs: 8_000, heard: [.me], levels: [:])
                screenshotTestSheet = true
            }
            if store.context.screenshot, LibraryLaunchContext.argument("-CassiniScreenshot") == "test-recording-refused", !screenshotTestSheet {
                TestRecordingController.shared.freezeRefusedForScreenshot()
                screenshotTestSheet = true
            }
            if store.context.screenshot, ["meeting","export","voices-question"].contains(LibraryLaunchContext.argument("-CassiniScreenshot") ?? ""), navigation.detail == nil,
               let meeting = store.visibleMeetings.first(where: { $0.title == (LibraryLaunchContext.argument("-CassiniScreenshot") == "export" ? "Budget review" : "Client call, Rossi & Partners") }) {
                store.selectedKey = meeting.libraryKey
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
        .overlay {
            LibraryWindowDropDestination(
                state: $dropState,
                sidebarDropWidth: showsFirstRun || columnVisibility == .detailOnly ? nil : sidebarWidth,
                showsVisualStates: (navigation.detail == nil || navigation.detail?.meeting.state.lifecycle == .saved) &&
                    !navigation.loading && !search.visible,
                onDropFiles: { LegacyOpening.openDocuments($0) }
            )
            .accessibilityHidden(true)
        }
        .preferredColorScheme(LibraryLaunchContext.screenshotDark ? .dark : (store.context.screenshot ? .light : nil))
    }
    private func trashButton(_ meeting: LibraryMeeting) -> some View {
        Button(UXText.text("meeting.moveToRecentlyDeleted")) {
            store.selectedKey = meeting.libraryKey
            trash.move(meeting,undoManager:undoManager ?? NSApp.keyWindow?.undoManager)
        }.accessibilityIdentifier("move-to-trash")
    }
    @ViewBuilder private var trashFailure: some View {
        if let meeting = trash.failure, (navigation.detail?.meeting.libraryKey ?? store.selectedKey) == meeting.libraryKey {
            HStack(spacing:12) {
                Text(UXText.text(trash.unsupported ? "meeting.trashUnsupported" : "meeting.trashFailed"))
                Spacer()
                if trash.unsupported {
                    Button(UXText.text("meeting.showInFiles")) { NSWorkspace.shared.activateFileViewerSelecting([meeting.folder]) }
                } else {
                    Button(UXText.text("common.tryAgain")) { trash.move(meeting,undoManager:undoManager) }.disabled(!trash.canTrash(meeting))
                }
            }.padding(12).foregroundStyle(CassiniTheme.warnInk).background(CassiniTheme.warnTint)
                .accessibilityIdentifier("trash-failure")
        }
    }
    private var toolbarTitle: some View {
        Text(UXText.text(search.visible ? "search.title" : "library.title")).font(.system(size: 15, weight: .bold))
            .accessibilityAddTraits(.isHeader).accessibilityIdentifier("library-toolbar-title")
    }
    // Attention takes precedence while failures remain. Only reveal an imported
    // selection once its row is present in the watcher snapshot.
    private var importScrollTarget: String? {
        guard store.preferences.filter == .all else { return nil }
        if let failed = importer.transientItems.first(where: {
            if case .failed = $0.state { return true }; return false
        }) { return "import-" + failed.id }
        if let key = store.importedSelection, store.selectedKey == key,
           store.visibleMeetings.contains(where: { $0.libraryKey == key }) { return key }
        return nil
    }
    private var split: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebarColumn
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { sidebarWidth = $0 }
                .toolbar {
                    sidebarToolbar
                }
                .frame(minWidth: 260, idealWidth: 340, maxWidth: 400)
                .navigationSplitViewColumnWidth(min: 260, ideal: 340, max: 400)
        } detail: {
            VStack(spacing: 0) {
                detailColumn
                #if DEBUG
                if RecordingFinalizationFixture.shared.waiting {
                    HStack {
                        Spacer()
                        Button("Finish fixture recording") { RecordingFinalizationFixture.shared.release() }
                            .accessibilityIdentifier("recording-fixture-finish")
                    }
                    .padding(8)
                }
                #endif
            }
            .frame(minWidth: 300)
            .toolbar {
                detailToolbar
            }
        }
        .searchable(
            text: $search.query,
            isPresented: $sidebarSearchPresented,
            placement: .sidebar,
            prompt: UXText.text("search.field.placeholder")
        )
    }

    private var showsLiveToolbarPill: Bool {
        RecordingOverview.active || RecordingOverview.saving
            || store.meetings.contains(where: { $0.state.lifecycle == .recording })
    }

    @ToolbarContentBuilder
    private var sidebarToolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button {
                LegacyOpening.chooseDocuments()
            } label: {
                ImportTrayIcon(size: 15, strokeWidth: 1.9)
            }
            .disabled(LibraryMoveCoordinator.shared.busy || !LibraryLocationModel.shared.available)
            .help(UXText.text("import.action"))
            .accessibilityLabel(UXText.text("import.action"))
            .accessibilityIdentifier("toolbar-import")
        }
        if !showsLiveToolbarPill {
            #if compiler(>=6.2)
            if #available(macOS 26.0, *) {
                ToolbarSpacer(.fixed, placement: .primaryAction)
                ToolbarItem(placement: .primaryAction) {
                    sidebarRecordButton
                }
                .sharedBackgroundVisibility(.hidden)
            } else {
                ToolbarItem(placement: .primaryAction) {
                    sidebarRecordButton
                }
            }
            #else
            ToolbarItem(placement: .primaryAction) {
                sidebarRecordButton
            }
            #endif
        }
    }

    @ViewBuilder
    private var liveRecordingToolbarControl: some View {
        if RecordingOverview.active, let started = RecordingOverview.startedAt {
            LiveRecordingPill(started: started, microphone: RecordingOverview.levels["microphone", default: 0], output: RecordingOverview.levels["output", default: 0])
        } else if RecordingOverview.saving {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(UXText.text("states.badge.saving")).fontWeight(.semibold).foregroundStyle(CassiniTheme.ink2)
            }
            .padding(.horizontal, 14)
            .frame(height: 30)
            .background(CassiniTheme.neutralPillFill, in: Capsule())
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("toolbar-saving")
        } else if let live = store.meetings.first(where: { $0.state.lifecycle == .recording }) {
            HStack(spacing: 8) {
                Circle().fill(CassiniTheme.recordInk).frame(width: 8, height: 8)
                Text(LibraryFormat.liveBadge(live.state.liveMs ?? 0)).fontWeight(.semibold).monospacedDigit().foregroundStyle(CassiniTheme.recordInk)
                VStack(spacing: 3) {
                    Capsule().fill(CassiniTheme.recordInk.opacity(0.6)).frame(width: 24, height: 4)
                    Capsule().fill(CassiniTheme.recordInk.opacity(0.3)).frame(width: 24, height: 4)
                }.accessibilityHidden(true)
                Text(UXText.text("common.stop")).font(.system(size: 12, weight: .semibold)).foregroundStyle(CassiniTheme.onRecord)
                    .padding(.horizontal, 12).frame(height: 24).background(CassiniTheme.record, in: Capsule())
            }.fixedSize().padding(.leading, 12).padding(.trailing, 4).frame(height: 30).background(CassiniTheme.recordTint, in: Capsule())
        }
    }

    private var sidebarRecordButton: some View {
        let enabled = RecordingOverview.canStart
        let title = UXText.text("common.record")
        return Button {
            sessionPlayback.stop()
            RecordCoordinator.shared.request(parent: store.context.root)
        } label: {
            HStack(spacing: 7) {
                Circle()
                    .fill(enabled ? CassiniTheme.onRecord : CassiniTheme.ink3)
                    .frame(width: 8, height: 8)
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(enabled ? CassiniTheme.onRecord : CassiniTheme.ink3)
            }
            .padding(.leading, 12)
            .padding(.trailing, 14)
            .frame(height: 30)
            .background(enabled ? CassiniTheme.record : CassiniTheme.chipFill, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(title)
        .accessibilityLabel(title)
        .accessibilityIdentifier("toolbar-record")
    }

    @ToolbarContentBuilder
    private var detailToolbar: some ToolbarContent {
        if let detail = navigation.savedDetail {
            let title = detail.meeting.title ?? UXText.text("library.untitled")
            let subtitle = store.format.previewSubtitle(
                detail.meeting.meetingTime,
                durationMs: detail.meeting.durationMs,
                received: detail.meeting.state.origin == .received,
                transcribedOnAnotherDevice: detail.meeting.transcribedOnAnotherDevice
            )
            let titleMaxWidth: CGFloat = toolbarWidth < 860 ? 140 : 280
            #if compiler(>=6.2)
            if #available(macOS 26.0, *) {
                ToolbarItem(placement: .navigation) {
                    MeetingWindowTitleView(
                        title: title,
                        subtitle: subtitle,
                        canRename: rename.canRename(detail.meeting),
                        maxWidth: titleMaxWidth,
                        onCommit: { newTitle in rename.renameInline(detail.meeting, to: newTitle) }
                    )
                }
                .sharedBackgroundVisibility(.hidden)
            } else {
                ToolbarItem(placement: .navigation) {
                    MeetingWindowTitleView(
                        title: title,
                        subtitle: subtitle,
                        canRename: rename.canRename(detail.meeting),
                        maxWidth: titleMaxWidth,
                        onCommit: { newTitle in rename.renameInline(detail.meeting, to: newTitle) }
                    )
                }
            }
            #else
            ToolbarItem(placement: .navigation) {
                MeetingWindowTitleView(
                    title: title,
                    subtitle: subtitle,
                    canRename: rename.canRename(detail.meeting),
                    maxWidth: titleMaxWidth,
                    onCommit: { newTitle in rename.renameInline(detail.meeting, to: newTitle) }
                )
            }
            #endif
        }
        if navigation.savedDetail == nil {
            ToolbarItem(placement: .automatic) { Spacer() }
        }
        if showsLiveToolbarPill {
            #if compiler(>=6.2)
            if #available(macOS 26.0, *) {
                ToolbarItem(placement: .primaryAction) {
                    liveRecordingToolbarControl
                }
                .sharedBackgroundVisibility(.hidden)
            } else {
                ToolbarItem(placement: .primaryAction) {
                    liveRecordingToolbarControl
                }
            }
            #else
            ToolbarItem(placement: .primaryAction) {
                liveRecordingToolbarControl
            }
            #endif
        }
        if let detail = navigation.savedDetail {
            if let spec = meetingTranscriptionToolbarSpec(detail) {
                ToolbarItem(placement: .primaryAction) {
                    Button(spec.title, action: spec.action)
                        .disabled(!spec.enabled)
                        .accessibilityIdentifier(spec.identifier)
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    if detail.find.visible { detail.find.close() }
                    else { detail.focusFind() }
                } label: {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(detail.find.visible ? CassiniTheme.accent : CassiniTheme.ink)
                }
                .help("\(UXText.text("meeting.find.placeholder")) (⌘F)")
                .accessibilityLabel(UXText.text("meeting.find.placeholder"))
                .accessibilityIdentifier("meeting-find-button")
            }
            #if compiler(>=6.2)
            if #available(macOS 26.0, *) {
                ToolbarSpacer(.fixed, placement: .primaryAction)
            }
            #endif
            ToolbarItemGroup(placement: .primaryAction) {
                let starred = store.isStarred(detail.meeting)
                Button {
                    store.toggleStar(detail.meeting)
                } label: {
                    Image(systemName: starred ? "star.fill" : "star")
                        .foregroundStyle(starred ? CassiniTheme.warnInk : CassiniTheme.ink)
                }
                .help(UXText.text(starred ? "meeting.unstar" : "meeting.star"))
                .accessibilityLabel(UXText.text(starred ? "meeting.unstar" : "meeting.star"))
                .accessibilityIdentifier("meeting-star")

                Button {
                    exporter.show(detail.meeting)
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .disabled(!MeetingExportCoordinator.canExport(detail.meeting))
                .help(UXText.text("common.exportEllipsis"))
                .accessibilityLabel(UXText.text("common.exportEllipsis"))
                .accessibilityIdentifier("meeting-export")

                Button {
                    store.selectedKey = detail.meeting.libraryKey
                    trash.move(detail.meeting, undoManager: undoManager ?? NSApp.keyWindow?.undoManager)
                } label: {
                    Image(systemName: "trash")
                }
                .disabled(!trash.canTrash(detail.meeting))
                .help(UXText.text("meeting.moveToRecentlyDeleted"))
                .accessibilityLabel(UXText.text("meeting.moveToRecentlyDeleted"))
                .accessibilityIdentifier("meeting-trash")
            }
        } else if recordingSelected, let meeting = store.selected {
            ToolbarItem(placement: .primaryAction) {
                LibraryToolbarAction(title: "", label: UXText.text("meeting.moreActions"), identifier: "recording-more-actions", style: .more, menu: {
                    LibraryToolbarAction.menu([
                        .init(title: UXText.text(store.isStarred(meeting) ? "meeting.unstar" : "meeting.star"), identifier: "recording-star") { store.toggleStar(meeting) },
                        .init(title: UXText.text("details.menu"), identifier: "recording-details") { recordingDetails.show(meeting) }
                    ])
                }) {}
            }
        }
    }

    private var sidebarColumn: some View {
        let todayTitle = UXText.text("format.today")
        let firstGroupIsToday = store.groups.first?.title == todayTitle
        return VStack(spacing: 0) {
            HStack {
                Picker(UXText.text("library.filters.a11y"), selection: $store.preferences.filter) {
                    Text(UXText.text("library.filter.all")).tag(LibraryPreferences.Filter.all)
                    Text(UXText.text("library.filter.starred")).tag(LibraryPreferences.Filter.starred)
                }
                .pickerStyle(.segmented)
                .controlSize(.regular)
                .labelsHidden()
                .fixedSize()
                .accessibilityIdentifier("library-filters")
                .onChange(of: store.preferences.filter) { _, _ in
                    store.selectedKeys.formIntersection(Set(store.visibleMeetings.map(\.libraryKey)))
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.top, 2)
            .padding(.bottom, 6)

            ScrollViewReader { proxy in
                ZStack {
                    List(selection: Binding(get: { store.selectedKeys }, set: {
                        let changed = $0 != store.selectedKeys
                        store.selectedKeys = $0
                        if changed, let window = NSApp.keyWindow,
                           LibraryKeyboardMenu.hasListFocus(in: window) {
                            openSelection(userInitiated: true)
                        }
                    })) {
                        if store.preferences.filter == .all && !importer.transientItems.isEmpty && !firstGroupIsToday {
                            Section {
                                ForEach(importer.transientItems) { item in
                                    transientImportRow(item)
                                }
                            } header: {
                                Text(todayTitle).font(.system(size: 11.5, weight: .bold)).foregroundStyle(CassiniTheme.ink2).textCase(nil)
                                    .padding(.horizontal, 10)
                                    .accessibilityIdentifier("library-day-header-importing")
                            }
                        }
                        if store.preferences.filter == .starred && store.visibleMeetings.isEmpty {
                            Text(UXText.text("library.starred.empty"))
                                .foregroundStyle(CassiniTheme.ink2)
                                .listRowBackground(Color.clear).listRowSeparator(.hidden)
                                .accessibilityIdentifier("library-starred-empty")
                        }
                        ForEach(Array(store.groups.enumerated()), id: \.element.id) { groupIndex, group in
                            Section {
                                if store.preferences.filter == .all && groupIndex == 0 && firstGroupIsToday {
                                    ForEach(importer.transientItems) { item in
                                        transientImportRow(item)
                                    }
                                }
                                ForEach(group.meetings, id: \.libraryKey) { meeting in
                                    row(meeting).tag(meeting.libraryKey).id(meeting.libraryKey)
                                        .background {
                                            LibraryRowOpenAnchor {
                                                guard !LibraryMoveCoordinator.shared.busy else { return }
                                                readTranscript(meeting)
                                            }.accessibilityHidden(true)
                                            if store.primarySelectedKey == meeting.libraryKey { LibraryMenuAnchor() }
                                        }
                                        .simultaneousGesture(TapGesture().onEnded {
                                            if NSEvent.modifierFlags.intersection([.command, .shift]).isEmpty {
                                                store.selectedKey = meeting.libraryKey
                                                openSelection(userInitiated: true)
                                                LibraryKeyboardMenu.focusList()
                                                DispatchQueue.main.async { LibraryKeyboardMenu.focusList() }
                                            }
                                        })
                                        .contextMenu {
                                            Button(UXText.text(store.isStarred(meeting) ? "meeting.unstar" : "meeting.star")) { store.toggleStar(meeting) }
                                                .accessibilityIdentifier("library-star")
                                            Button(UXText.text("meeting.renameEllipsis")) { store.selectedKey = meeting.libraryKey; rename.show(meeting) }
                                                .disabled(store.selectedKeys.count > 1 || !rename.canRename(meeting)).accessibilityIdentifier("library-rename")
                                            Button(UXText.text("common.exportEllipsis")) { store.selectedKey = meeting.libraryKey; exporter.show(meeting) }
                                                .disabled(store.selectedKeys.count > 1 || !MeetingExportCoordinator.canExport(meeting))
                                                .onAppear {
                                                    if !store.selectedKeys.contains(meeting.libraryKey) {
                                                        store.selectedKey = meeting.libraryKey
                                                    }
                                                }
                                            if !store.selectedKeys.isEmpty {
                                                Button(UXText.text("export.zip.selected")) { bulkExporter.exportSelected() }
                                                    .disabled(!bulkExporter.canExportSelected)
                                                    .accessibilityIdentifier("library-export-selected-zip")
                                            }
                                            Button(UXText.text("export.zip.all")) { bulkExporter.exportAll() }
                                                .disabled(!bulkExporter.canExportAll)
                                                .accessibilityIdentifier("library-export-all-zip")
                                            if store.selectedKeys.count <= 1 && trash.canTrash(meeting) { Divider(); trashButton(meeting) }
                                        }
                                        .listRowSeparator(.hidden)
                                        .listRowBackground(Color.clear)
                                        .listRowInsets(EdgeInsets(top: 3, leading: 10, bottom: 3, trailing: 10))
                                        .accessibilityIdentifier("meeting-" + meeting.libraryKey)
                                }
                            } header: {
                                Text(group.title).font(.system(size: 11.5, weight: .bold)).foregroundStyle(CassiniTheme.ink2).textCase(nil)
                                    .padding(.horizontal, 10)
                                    .accessibilityIdentifier("library-day-header-" + (group.meetings.first?.libraryKey ?? "empty"))
                            }
                        }
                        if !store.meetings.isEmpty, store.meetings.allSatisfy({ $0.state.origin == .received }) {
                            Text(UXText.text("received.libraryHint")).font(.system(size: 11.5)).foregroundStyle(CassiniTheme.ink2)
                                .listRowBackground(Color.clear).listRowSeparator(.hidden)
                        }
                    }
                    .listStyle(.sidebar)
                    .scrollContentBackground(.hidden)
                    .opacity(dropState.dimsListContent ? 0.30 : 1.0)
                    .accessibilityLabel(UXText.text("library.listPane.a11y"))

                    LibraryDropListOverlay(state: dropState)
                }
                .onChange(of: importScrollTarget, initial: true) { _, target in
                    if let target {
                        proxy.scrollTo(target, anchor: .center)
                        store.consumeImportedSelection(target)
                    }
                }
            }

            LibraryDropHintFooter(entered: dropState.showsWindowOutline)
        }
    }

    @ViewBuilder
    private var detailColumn: some View {
        if let detail = navigation.savedDetail {
            MeetingView(model: detail, format: store.format).id(ObjectIdentifier(detail))
        } else if let meeting = store.selected, meeting.state.lifecycle != .saved {
            RecordingPageView(meeting: meeting, format: store.format).id(meeting.libraryKey)
        } else if navigation.loading {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if store.selectedKeys.count > 1 {
            VStack {
                Spacer()
                Button(UXText.text("export.zip.selected")) { bulkExporter.exportSelected() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(!bulkExporter.canExportSelected)
                    .accessibilityIdentifier("preview-export-selected-zip")
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(CassiniTheme.paneGround)
        } else {
            Text(UXText.text("meeting.emptySelection")).foregroundStyle(CassiniTheme.ink2)
                .frame(maxWidth: .infinity, maxHeight: .infinity).background(CassiniTheme.paneGround)
                .accessibilityIdentifier("meeting-empty-selection")
        }
    }
    private func transientImportRow(_ item: LibraryImportCoordinator.TransientItem) -> some View {
        let isFailed: Bool
        let failureDetail: String?
        switch item.state {
        case .importing:
            isFailed = false
            failureDetail = nil
        case .failed(let detail):
            isFailed = true
            failureDetail = detail
        }
        let presentation = isFailed ? LibraryBadgeCatalog.needsAttentionPresentation : LibraryBadgeCatalog.importingPresentation
        return MeetingCard(isSelected: false) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    Text(item.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(CassiniTheme.ink)
                        .lineLimit(1)
                    Spacer(minLength: 2)
                    if isFailed {
                        Button(UXText.text("common.done")) {
                            importer.dismissTransientItem(item.id)
                        }
                        .buttonStyle(.borderless)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(CassiniTheme.accentInk)
                        .accessibilityIdentifier("dismiss-failed-import-" + item.fileName)
                    }
                }
                HStack(spacing: 6) {
                    Text(store.format.rowTime(item.startedAt))
                        .foregroundStyle(CassiniTheme.ink2)
                        .monospacedDigit()
                        .fixedSize()
                    if let presentation {
                        catalogStatusBadge(presentation, onAccent: false)
                    }
                    Text(failureDetail ?? item.fileName)
                        .foregroundStyle(CassiniTheme.ink2)
                        .lineLimit(1)
                }
                .font(.system(size: 11.5))
            }
        }
        .id("import-" + item.id)
        .help(failureDetail ?? "")
        .contextMenu {
            if isFailed {
                Button(UXText.text("common.done")) { importer.dismissTransientItem(item.id) }
            }
        }
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets(top: 3, leading: 10, bottom: 3, trailing: 10))
        .accessibilityIdentifier((isFailed ? "failed-import-" : "importing-") + item.fileName)
    }
    private var toolbarControl: some View {
        HStack(spacing: 4) {
            LibraryImportHeaderButton(
                enabled: !LibraryMoveCoordinator.shared.busy && LibraryLocationModel.shared.available
            ) {
                LegacyOpening.chooseDocuments()
            }
            if RecordingOverview.active, let started = RecordingOverview.startedAt {
                LiveRecordingPill(started: started, microphone: RecordingOverview.levels["microphone", default: 0], output: RecordingOverview.levels["output", default: 0])
            } else if RecordingOverview.saving {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(UXText.text("states.badge.saving")).fontWeight(.semibold).foregroundStyle(CassiniTheme.ink2)
                }
                .padding(.horizontal, 14)
                .frame(height: 34)
                .background(CassiniTheme.neutralPillFill, in: Capsule())
                .accessibilityElement(children:.contain)
                .accessibilityIdentifier("toolbar-saving")
            } else if let live = store.meetings.first(where: { $0.state.lifecycle == .recording }) {
                // Read-only header placeholder until UX5 owns transport/levels.
                HStack(spacing: 8) {
                    Circle().fill(CassiniTheme.recordInk).frame(width: 8, height: 8)
                    Text(LibraryFormat.liveBadge(live.state.liveMs ?? 0)).fontWeight(.semibold).monospacedDigit().foregroundStyle(CassiniTheme.recordInk)
                    VStack(spacing: 3) {
                        Capsule().fill(CassiniTheme.recordInk.opacity(0.6)).frame(width: 24, height: 4)
                        Capsule().fill(CassiniTheme.recordInk.opacity(0.3)).frame(width: 24, height: 4)
                    }.accessibilityHidden(true)
                    Text(UXText.text("common.stop")).font(.system(size: 12, weight: .semibold)).foregroundStyle(CassiniTheme.onRecord)
                        .padding(.horizontal, 12).frame(height: 26).background(CassiniTheme.record, in: Capsule())
                }.fixedSize().padding(.leading, 13).padding(.trailing, 4).frame(height: 34).background(CassiniTheme.recordTint, in: Capsule())
            } else if !showsFirstRun || search.visible { recordButton(big: false) }
        }.accessibilityElement(children: .contain)
    }
    private func row(_ meeting: LibraryMeeting) -> some View {
        let selected = store.selectedKeys.contains(meeting.libraryKey)
        let presentation = LibraryBadgeCatalog.presentation(for: meeting)
        let showDuration = meeting.durationMs != nil && presentation?.kind != "recording" && presentation?.kind != "saving"
        let trailingMeta = rowTrailingMeta(meeting, badgeKind: presentation?.kind)
        return MeetingCard(isSelected: selected) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    if store.isStarred(meeting) {
                        Image(systemName:"star.fill")
                            .font(.system(size: 10.5))
                            .foregroundStyle(CassiniTheme.warnInk)
                            .accessibilityLabel(UXText.text("library.row.starred.a11y"))
                            .accessibilityIdentifier("library-starred-" + meeting.libraryKey)
                    }
                    Text(meeting.title ?? UXText.text("library.untitled"))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(CassiniTheme.ink)
                        .lineLimit(1)
                    Spacer(minLength: 2)
                    if showDuration, let durationMs = meeting.durationMs {
                        Text(LibraryFormat.meetingDuration(durationMs))
                            .font(.system(size: 11.5))
                            .foregroundStyle(CassiniTheme.ink2)
                            .monospacedDigit()
                            .fixedSize()
                    }
                }
                HStack(spacing: 6) {
                    if let start = meeting.meetingTime {
                        Text(store.format.rowTime(start))
                            .foregroundStyle(CassiniTheme.ink2)
                            .monospacedDigit()
                            .fixedSize()
                    }
                    if let presentation {
                        catalogStatusBadge(presentation, onAccent: false)
                        if let trailingMeta {
                            Text(trailingMeta)
                                .foregroundStyle(CassiniTheme.ink2)
                                .lineLimit(1)
                        }
                    } else if let trailingMeta {
                        if meeting.meetingTime != nil {
                            Text("·")
                                .foregroundStyle(CassiniTheme.ink2)
                                .accessibilityHidden(true)
                        }
                        Text(trailingMeta)
                            .foregroundStyle(CassiniTheme.ink2)
                            .lineLimit(1)
                    }
                }
                .font(.system(size: 11.5))
            }
        }
    }
    // L-51, L-53: duration sits top-right; line two shows time, optional status badge (no dot after a badge),
    // and speaker names (with a standalone middle dot when no badge is present).
    private func rowTrailingMeta(_ meeting: LibraryMeeting, badgeKind: String?) -> String? {
        switch badgeKind {
        case "recording":
            return meeting.isBrowserCapture ? UXText.text("common.listeningInsideBrowser") : nil
        case "saving", "transcribing":
            return nil
        default:
            let names = LibraryFormat.rowMeta(durationMs: nil, names: meeting.speakerNames)
            return names.isEmpty ? nil : names
        }
    }
    private func catalogStatusBadge(_ presentation: CatalogBadgePresentation, onAccent: Bool = false) -> some View {
        CatalogStatusBadge(presentation: presentation, isAnimating: !store.context.screenshot && scenePhase == .active, onAccent: onAccent)
            .accessibilityAddTraits(.isStaticText)
    }

    private var autoTag: some View {
        Text(UXText.text("common.autoTag")).font(.system(size: 10, weight: .medium)).foregroundStyle(CassiniTheme.ink2)
            .padding(.horizontal, 4).overlay(RoundedRectangle(cornerRadius: 4).stroke(CassiniTheme.tagStroke))
            .help(UXText.text("common.autoTag.tooltip"))
    }
    private var firstRun: some View {
        GeometryReader { geometry in
            let compact = geometry.size.height < FirstRunHeroMetrics.compactHeight
            ScrollView {
                VStack(alignment:.leading,spacing:compact ? FirstRunHeroMetrics.compactGap : FirstRunHeroMetrics.gap) {
                    HStack(spacing:32) {
                        CassiniBrandMark(height:FirstRunHeroMetrics.mark)
                        FirstRunWave().frame(maxWidth:501).frame(height:FirstRunHeroMetrics.mark)
                    }.padding(.bottom,4)
                    VStack(alignment:.leading,spacing:0) {
                        Text(UXText.text("firstRun.hero.title"))
                            .foregroundStyle(CassiniTheme.ink).accessibilityIdentifier("first-run-hero-title")
                        Text(UXText.text("firstRun.hero.subtitle.computer"))
                            .foregroundStyle(CassiniTheme.ink3).accessibilityIdentifier("first-run-hero-subtitle")
                    }.font(.system(size:FirstRunHeroMetrics.headline,weight:.bold)).tracking(-1.92)
                        .lineLimit(1).minimumScaleFactor(0.45)
                        .frame(maxWidth:.infinity,alignment:.leading).accessibilityAddTraits(.isHeader)
                    if let line = RecordingOverview.libraryDiskLine {
                        Text(line).foregroundStyle(CassiniTheme.warningNotice)
                    }
                    HStack(spacing:14) {
                        recordButton(big:true).fixedSize()
                        FirstRunShortcut()
                    }
                    FirstRunPrivacy(root:store.context.root,screenshot:store.context.screenshot)
                }.padding(.horizontal,FirstRunHeroMetrics.horizontalPadding)
                    .padding(.vertical,compact ? FirstRunHeroMetrics.compactPadding : FirstRunHeroMetrics.padding)
                    .frame(maxWidth:FirstRunHeroMetrics.maxWidth + 2 * FirstRunHeroMetrics.horizontalPadding,alignment:.leading)
                    .padding(.bottom,40)
                    .frame(maxWidth:.infinity,minHeight:geometry.size.height,alignment:.center)
            }.accessibilityElement(children:.contain).accessibilityLabel(UXText.text("library.title"))
                .accessibilityAddTraits(.isHeader).accessibilityIdentifier("first-run-library")
        }.background(CassiniTheme.surface)
            .overlay { LibraryDropListOverlay(state:dropState) }
    }
    @ViewBuilder private func recordButton(big: Bool) -> some View {
        let saving = big && RecordingOverview.saving
        let enabled = RecordingOverview.canStart
        let title = UXText.text(saving ? "states.badge.saving" : "common.record")
        if !big {
            LibraryToolbarAction(title:title,label:title,identifier:"toolbar-record",style:.record,enabled:enabled) {
                sessionPlayback.stop(); RecordCoordinator.shared.request(parent: store.context.root)
            }.frame(minWidth:90).fixedSize(horizontal:true,vertical:false)
        } else {
        Button { sessionPlayback.stop(); RecordCoordinator.shared.request(parent: store.context.root) } label: {
            HStack(spacing: 9) {
                if saving {
                    ProgressView().controlSize(.small)
                } else {
                    Circle().fill(enabled ? CassiniTheme.onRecord : CassiniTheme.ink3).frame(width:10,height:10)
                }
                Text(title).fontWeight(.semibold)
            }.font(.system(size:15)).padding(.leading,20).padding(.trailing,24).frame(height:46)
                .foregroundStyle(saving ? CassiniTheme.ink2 : enabled ? CassiniTheme.onRecord : CassiniTheme.ink3)
                .background(saving || !enabled ? CassiniTheme.chipFill : CassiniTheme.record, in: Capsule())
        }.buttonStyle(.plain).disabled(!enabled).accessibilityLabel(title).accessibilityIdentifier("first-run-record")
        }
    }
    private func openSelection(userInitiated: Bool = false) {
        guard !search.visible, store.loaded, !LibraryMoveCoordinator.shared.busy, !trash.busy else { return }
        if navigation.detail?.fileURL != nil && !userInitiated { return }
        if let meeting = store.selected {
            #if DEBUG
            if store.context.screenshot, navigation.detail == nil,
               ["meeting", "export", "recording"].contains(LibraryLaunchContext.argument("-CassiniScreenshot") ?? "") { return }
            #endif
            if meeting.state.lifecycle == .saving {
                sessionPlayback.stop()
                navigation.back()
            } else if navigation.detail?.meeting.libraryKey != meeting.libraryKey {
                sessionPlayback.stop()
                navigation.open(meeting, frozen: store.context.screenshot, activate: false)
            }
        } else if store.selectedKeys.count > 1 || store.selectedKeys.isEmpty { navigation.back() }
    }

    private func readTranscript(_ meeting: LibraryMeeting) {
        sessionPlayback.stop(); navigation.open(meeting)
    }
    private struct TranscriptionToolbarSpec {
        let title: String
        let identifier: String
        let enabled: Bool
        let action: () -> Void
    }
    /// The title's leading edge (sidebar-aligned inset after back/record) plus
    /// the toolbar's own gaps and trailing margin, calibrated so the widest
    /// English layout that is known to fit at 1120 pt keeps fitting.
    private static let meetingTitleFixedReserve: CGFloat = 236 + 110
    private static let meetingTitleMinimumWidth: CGFloat = 200
    private static let meetingToolbarItemSpacing: CGFloat = 12
    /// Width the title must leave free, measured from the localized trailing
    /// toolbar labels so long translations never push "…" off the window.
    private func meetingTitleReservedWidth(_ detail: MeetingDetailModel, includingTranscription: Bool) -> CGFloat {
        var trailing = LibraryToolbarAction.width(title:UXText.text("common.exportEllipsis"),style:.capsule)
            + Self.meetingToolbarItemSpacing + LibraryToolbarAction.width(title:"",style:.more)
        if includingTranscription, let spec = meetingTranscriptionToolbarSpec(detail) {
            trailing += LibraryToolbarAction.width(title:spec.title,style:.bordered) + Self.meetingToolbarItemSpacing
        }
        return Self.meetingTitleFixedReserve + trailing
    }
    /// The transcription action moves into the "…" menu when the window is too
    /// narrow to show it next to a readable title.
    private func meetingShowsTranscriptionInToolbar(_ detail: MeetingDetailModel) -> Bool {
        guard meetingTranscriptionToolbarSpec(detail) != nil else { return false }
        return toolbarWidth - meetingTitleReservedWidth(detail,includingTranscription:true) >= Self.meetingTitleMinimumWidth
    }
    private func meetingTranscriptionToolbarSpec(_ detail: MeetingDetailModel) -> TranscriptionToolbarSpec? {
        let busy = LibraryMoveCoordinator.shared.busy || transcriptionQueue.isStopping(detail.meeting.folder)
        if detail.meeting.canWriteDown && detail.meeting.state.transcript == .none {
            let title = UXText.text("common.writeDown")
            return .init(title:title,identifier:"meeting-write-down",enabled:!busy) { TranscriptionQueue.shared.writeDown(detail) }
        }
        return nil
    }
    @ViewBuilder
    private func previewTranscriptionButton(_ meeting: LibraryMeeting) -> some View {
        let busy = LibraryMoveCoordinator.shared.busy || transcriptionQueue.isStopping(meeting.folder)
        if meeting.canWriteDown && meeting.state.transcript == .none && !meeting.metadataReadOnly {
            Button(UXText.text("common.writeDown")) { TranscriptionQueue.shared.enqueue(meeting) }
                .buttonStyle(.bordered).disabled(busy).accessibilityIdentifier("preview-write-down")
        } else if [.queued,.running].contains(meeting.state.transcript) && !meeting.metadataReadOnly {
            Button(UXText.text("common.stop")) { TranscriptionQueue.shared.stop(meeting) }
                .buttonStyle(.bordered).disabled(busy).accessibilityIdentifier("preview-stop-transcription")
        }
    }
}

private struct LibraryWindowTitleModifier: ViewModifier {
    let savedDetail: MeetingDetailModel?
    let showsFirstRun: Bool
    let searchVisible: Bool
    let format: LibraryFormat
    let canRename: Bool
    let onRename: (MeetingDetailModel, String) -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        if let detail = savedDetail, !showsFirstRun, !searchVisible {
            let subtitle = format.previewSubtitle(
                detail.meeting.meetingTime,
                durationMs: detail.meeting.durationMs,
                received: detail.meeting.state.origin == .received,
                transcribedOnAnotherDevice: detail.meeting.transcribedOnAnotherDevice
            )
            content
                .navigationTitle(detail.meeting.title ?? UXText.text("library.untitled"))
                .navigationSubtitle(subtitle)
                .toolbar(removing: .title)
        } else {
            content
                .navigationTitle(UXText.text("app.name"))
                .toolbar(removing: .title)
        }
    }
}

/// Inline-editable meeting title and subtitle hosted in the detail toolbar's
/// leading `.navigation` placement. Clicking the title edits in place and routes
/// commits through `MeetingRenameCoordinator.renameInline` on both macOS 15 and 26.
private struct MeetingWindowTitleView: View {
    let title: String
    let subtitle: String
    let canRename: Bool
    var maxWidth: CGFloat = 280
    let onCommit: (String) -> Void
    @State private var editing = false
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            if editing && canRename {
                InlineToolbarTitleField(
                    initialText: title,
                    onCommit: { newValue in
                        editing = false
                        onCommit(newValue)
                    },
                    onCancel: {
                        editing = false
                    }
                )
                .frame(minWidth: 120, idealWidth: min(220, maxWidth), maxWidth: maxWidth, minHeight: 20, maxHeight: 20)
            } else if canRename {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(CassiniTheme.ink)
                    .lineLimit(1)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(hovering ? CassiniTheme.ink.opacity(0.08) : Color.clear, in: RoundedRectangle(cornerRadius: 4))
                    .contentShape(Rectangle())
                    .onHover { hovering = $0 }
                    .onTapGesture { editing = true }
                    .accessibilityIdentifier("meeting-window-title")
            } else {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(CassiniTheme.ink)
                    .lineLimit(1)
                    .accessibilityIdentifier("meeting-window-title")
            }
            Text(subtitle)
                .font(.system(size: 11))
                .foregroundStyle(CassiniTheme.secondaryInk)
                .lineLimit(1)
                .padding(.horizontal, canRename ? 4 : 0)
                .accessibilityIdentifier("meeting-window-subtitle")
        }
        .frame(minWidth: 60, maxWidth: maxWidth, alignment: .leading)
        .onChange(of: title) { _, _ in editing = false }
        .onChange(of: canRename) { _, allowed in if !allowed { editing = false } }
    }
}

private struct InlineToolbarTitleField: NSViewRepresentable {
    let initialText: String
    let onCommit: (String) -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onCommit: onCommit, onCancel: onCancel) }

    func makeNSView(context: Context) -> FocusableTitleField {
        let field = FocusableTitleField()
        field.stringValue = initialText
        field.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        field.isEditable = true
        field.isSelectable = true
        field.lineBreakMode = .byTruncatingTail
        field.delegate = context.coordinator
        field.setAccessibilityIdentifier("meeting-window-title-editor")
        return field
    }

    func updateNSView(_ view: FocusableTitleField, context: Context) {
        context.coordinator.onCommit = onCommit
        context.coordinator.onCancel = onCancel
    }

    final class FocusableTitleField: NSTextField {
        private var didFocus = false
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard !didFocus, let window else { return }
            didFocus = true
            DispatchQueue.main.async { [weak self, weak window] in
                guard let self, let window else { return }
                if window.makeFirstResponder(self) {
                    self.currentEditor()?.selectAll(nil)
                }
            }
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var onCommit: (String) -> Void
        var onCancel: () -> Void
        private var finished = false
        init(onCommit: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
            self.onCommit = onCommit
            self.onCancel = onCancel
        }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                guard !finished else { return true }
                finished = true
                onCommit(control.stringValue)
                return true
            }
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                guard !finished else { return true }
                finished = true
                onCancel()
                return true
            }
            return false
        }
        func controlTextDidEndEditing(_ obj: Notification) {
            guard !finished, let field = obj.object as? NSTextField else { return }
            finished = true
            onCommit(field.stringValue)
        }
    }
}

private struct ConditionalFirstRunToolbarChrome: ViewModifier {
    let enabled: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if enabled {
            content.cassiniUnifiedToolbarChrome()
        } else {
            content
        }
    }
}

/// Native groups expose one action each, avoiding SwiftUI toolbar wrappers that
/// duplicate their child button's role and identifier in the accessibility tree.
struct LibraryToolbarAction: NSViewRepresentable {
    enum Style: Equatable { case back, record, stop, saving, capsule, bordered, more }
    let title: String, label: String, identifier: String
    let style: Style
    var enabled = true
    var menu: (() -> NSMenu)? = nil
    #if DEBUG
    var fixtureOnLaidOut: ((String) -> Void)? = nil
    #endif
    let action: () -> Void
    func makeNSView(context: Context) -> LibraryToolbarActionView { LibraryToolbarActionView() }
    func updateNSView(_ view: LibraryToolbarActionView, context: Context) {
        var effective=self
        effective.enabled = enabled && MeetingRenameCoordinator.shared.presentation != .speakers
        view.update(effective)
    }
    struct MenuEntry {
        let title: String, identifier: String
        var enabled = true
        let action: () -> Void
    }
    static func menu(_ entries: [MenuEntry]) -> NSMenu {
        let menu = NSMenu(); menu.autoenablesItems = false
        for entry in entries {
            let item = ActionItem(title:entry.title,handler:entry.action)
            item.isEnabled = entry.enabled; item.setAccessibilityIdentifier(entry.identifier); menu.addItem(item)
        }
        return menu
    }
    /// Intrinsic width of a toolbar action; shared with layout code that must
    /// reserve room for these buttons before AppKit lays them out.
    static func width(title: String, style: Style) -> CGFloat {
        switch style {
        case .back, .more: return 28
        default:
            let text = ceil((title as NSString).size(withAttributes:[.font:font]).width)
            return text + 28 + (style == .record ? 18 : style == .saving ? 22 : 0)
        }
    }
    static let font = NSFont.systemFont(ofSize:13,weight:.semibold)
    static func singleMenu(title: String, identifier: String, action: @escaping () -> Void) -> NSMenu {
        let menu = NSMenu(); menu.autoenablesItems = false
        let item = ActionItem(title:title,handler:action)
        item.setAccessibilityIdentifier(identifier); menu.addItem(item); return menu
    }
    private final class ActionItem: NSMenuItem {
        private let handler: () -> Void
        init(title: String, handler: @escaping () -> Void) {
            self.handler = handler; super.init(title:title,action:nil,keyEquivalent:"")
            target = self; action = #selector(invoke(_:))
        }
        required init(coder: NSCoder) { fatalError("Programmatic menu item") }
        @objc private func invoke(_ sender: Any?) { DispatchQueue.main.async { [handler] in handler() } }
    }
}
final class LibraryToolbarActionView: NSView {
    private final class ActionButton: NSButton {
        var spokenLabel = ""
        override func accessibilityLabel() -> String? { spokenLabel }
    }
    private let button = ActionButton()
    private let spinner: NSProgressIndicator = {
        let indicator = NSProgressIndicator()
        indicator.style = .spinning; indicator.controlSize = .small
        indicator.isDisplayedWhenStopped = false; indicator.isHidden = true
        indicator.setAccessibilityElement(false)
        return indicator
    }()
    private var action: (() -> Void)?, makeMenu: (() -> NSMenu)?
    private var currentStyle: LibraryToolbarAction.Style = .bordered
    #if DEBUG
    private var fixtureOnLaidOut: ((String) -> Void)?
    #endif
    private var size = NSSize(width:28,height:34)
    override init(frame: NSRect) {
        super.init(frame:frame)
        setAccessibilityElement(true); setAccessibilityRole(.group)
        button.target = self; button.action = #selector(invoke(_:))
        button.setButtonType(.momentaryPushIn); button.wantsLayer = true; button.layer?.cornerRadius = 6
        addSubview(button); addSubview(spinner); setAccessibilityChildren([button])
    }
    required init?(coder: NSCoder) { nil }
    override var intrinsicContentSize: NSSize { size }
    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        #if DEBUG
        scheduleFixtureLayoutNotification()
        #endif
    }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); applyLayerFill() }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); applyLayerFill() }
    private func applyLayerFill() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let disabledRecord = currentStyle == .record && !button.isEnabled
            let fill: NSColor = disabledRecord ? CassiniTheme.nsChipFill : [.stop,.record].contains(currentStyle) ? CassiniTheme.nsRecord : [.saving,.capsule].contains(currentStyle) ? CassiniTheme.nsChipFill : .clear
            button.layer?.backgroundColor = fill.cgColor
        }
    }
    override func layout() {
        super.layout(); button.frame = bounds
        spinner.frame = NSRect(x:10,y:(bounds.height - 16) / 2,width:16,height:16)
        #if DEBUG
        if superview != nil, button.frame.width > 0 {
            fixtureOnLaidOut?(button.accessibilityIdentifier())
        }
        #endif
    }
    func update(_ value: LibraryToolbarAction) {
        action = value.action; makeMenu = value.menu; currentStyle = value.style
        #if DEBUG
        fixtureOnLaidOut = value.fixtureOnLaidOut
        #endif
        // SwiftUI otherwise borrows the only child's identifier/label for its
        // representable proxy. Keep the container distinct from the action.
        setAccessibilityIdentifier(value.identifier + "-group"); setAccessibilityLabel("")
        button.spokenLabel = value.label; button.setAccessibilityIdentifier(value.identifier)
        button.toolTip = value.label; button.isEnabled = value.enabled
        let font = LibraryToolbarAction.font
        button.font = font; button.image = nil
        button.isBordered = value.style == .bordered; button.bezelStyle = .rounded
        button.layer?.cornerRadius = [.record,.stop,.saving,.capsule].contains(value.style) ? 17 : 6
        button.imagePosition = .imageLeft
        let disabledRecord = value.style == .record && !value.enabled
        let tint: NSColor = disabledRecord ? CassiniTheme.nsInk3 : [.stop,.record].contains(value.style) ? CassiniTheme.nsOnRecord : value.style == .saving ? CassiniTheme.nsInk2 : CassiniTheme.nsInk
        button.attributedTitle = NSAttributedString(string:value.title,attributes:[.font:font,.foregroundColor:tint])
        applyLayerFill()
        size = NSSize(width:LibraryToolbarAction.width(title:value.title,style:value.style),height:34)
        if value.style == .saving { spinner.isHidden = false; spinner.startAnimation(nil) }
        else { spinner.stopAnimation(nil); spinner.isHidden = true }
        switch value.style {
        case .back, .more:
            button.image = NSImage(systemSymbolName:value.style == .back ? "chevron.left" : "ellipsis",accessibilityDescription:nil)
            button.imagePosition = .imageOnly; button.contentTintColor = CassiniTheme.nsInk
        case .record:
            let dot = value.enabled ? CassiniTheme.nsOnRecord : CassiniTheme.nsInk3
            button.image = NSImage(size:NSSize(width:18,height:10),flipped:false) { _ in
                dot.setFill(); NSBezierPath(ovalIn:NSRect(x:0,y:0,width:10,height:10)).fill(); return true
            }
            button.imageHugsTitle = true
        case .saving:
            button.image = NSImage(size:NSSize(width:22,height:16))
            button.imageHugsTitle = true
        default: break
        }
        needsLayout = true; invalidateIntrinsicContentSize()
        #if DEBUG
        scheduleFixtureLayoutNotification()
        #endif
    }
    #if DEBUG
    private func scheduleFixtureLayoutNotification() {
        guard fixtureOnLaidOut != nil else { return }
        Task { @MainActor [weak self] in
            guard let self, let callback = self.fixtureOnLaidOut, self.superview != nil else { return }
            var root: NSView = self
            while let parent = root.superview { root = parent }
            if self.needsLayout || self.button.frame.width == 0 {
                root.layoutSubtreeIfNeeded()
            } else {
                callback(self.button.accessibilityIdentifier())
            }
        }
    }
    #endif
    @objc private func invoke(_ sender: Any?) {
        guard MeetingRenameCoordinator.shared.presentation != .speakers else {return}
        if let makeMenu { makeMenu().popUp(positioning:nil,at:NSPoint(x:0,y:0),in:self) }
        else { action?() }
    }
}

struct UpdateReadyFooter: View {
    let updates: ApplicationUpdates
    var body: some View {
        if updates.readyWhenIdle {
            Text(UXText.text("updates.readyWhenIdle")).font(.system(size:11.5)).foregroundStyle(CassiniTheme.ink2)
                .frame(maxWidth:.infinity,alignment:.leading).padding(.horizontal,18).padding(.vertical,8)
                .accessibilityIdentifier("library-update-ready")
        }
    }
}

// D105: desktop headline size is decided; narrow/short windows remain usable.
private enum FirstRunHeroMetrics {
    static let headline: CGFloat = 64
    static let maxWidth: CGFloat = 860
    static let horizontalPadding: CGFloat = 48
    static let gap: CGFloat = 24
    static let compactGap: CGFloat = 16
    static let mark: CGFloat = 40
    static let padding: CGFloat = 32
    static let compactPadding: CGFloat = 24
    static let compactHeight: CGFloat = 600
}

/// D105 keeps the placeholder in its localized position, rendered as one key chip.
private struct FirstRunShortcut: View {
    private var parts: [String] { UXText.text("firstRun.shortcutLine").components(separatedBy:"{shortcut}") }
    var body: some View {
        HStack(spacing:0) {
            Text(parts[0])
            Text(UXText.text("common.shortcut.record"))
                .font(.system(size:13.5,weight:.semibold))
                .padding(.horizontal,5).padding(.vertical,2)
                .background(CassiniTheme.chipFill,in:RoundedRectangle(cornerRadius:4))
                .overlay(RoundedRectangle(cornerRadius:4).stroke(CassiniTheme.tagStroke))
                .fixedSize()
            Text(parts.dropFirst().joined(separator:"{shortcut}"))
                .fixedSize(horizontal:false,vertical:true)
        }.font(.system(size:15)).foregroundStyle(CassiniTheme.ink2)
            .accessibilityElement(children:.ignore)
            .accessibilityLabel(UXText.text("firstRun.shortcutLine",["shortcut":UXText.text("common.shortcut.record")]))
            .accessibilityIdentifier("first-run-shortcut")
    }
}

private struct FirstRunPrivacy: View {
    // The observed Library context republishes this after Move completes, so
    // the displayed folder and the link target change together.
    let root: URL
    let screenshot: Bool
    private var move: LibraryMoveCoordinator { .shared }
    private static let folderLink = URL(string:"cassini-first-run://library")!
    private var line: AttributedString {
        // Build attributed text directly: folder names are literal, including
        // Markdown, braces, and punctuation. Only the catalog placeholder links.
        let parts = UXText.text("firstRun.privacy.computer").components(separatedBy:"{folder}")
        let folder = LibraryLocationModel.display(screenshot ? LibraryLocation.standardRoot : root)
            .replacingOccurrences(of:" › ",with:"/")
        var result = AttributedString(parts[0])
        var link = AttributedString(folder)
        link.link = Self.folderLink
        link.foregroundColor = CassiniTokens.accent
        link.font = .system(size:14,weight:.semibold)
        link.underlineStyle = .single
        result.append(link)
        result.append(AttributedString(parts.dropFirst().joined(separator:"{folder}")))
        return result
    }
    var body: some View {
        HStack(alignment:.firstTextBaseline,spacing:6) {
            Image(systemName:"shield").font(.system(size:15)).foregroundStyle(CassiniTokens.accent).accessibilityHidden(true)
            Text(line).fixedSize(horizontal:false,vertical:true)
                .help(UXText.text("firstRun.openFolder.tooltip"))
                .environment(\.openURL,OpenURLAction { url in
                    guard url == Self.folderLink else { return .discarded }
                    openFolder()
                    return .handled
                })
                .accessibilityIdentifier("first-run-privacy")
            Button { move.choose(parent:NSApp.keyWindow) } label: {
                Image(systemName:"pencil").font(.system(size:12)).frame(width:20,height:20)
                    .contentShape(Rectangle())
            }.buttonStyle(.plain).foregroundStyle(CassiniTheme.ink3)
                .help(UXText.text("firstRun.changeFolder.tooltip"))
                .accessibilityLabel(UXText.text("firstRun.changeFolder"))
                .accessibilityIdentifier("first-run-change-folder").disabled(!move.canChoose)
        }.font(.system(size:14)).foregroundStyle(CassiniTheme.ink2)
    }
    private func openFolder() {
        let root = root
        Task {
            do {
                // A new default Library need not exist yet. Prepare it off the
                // main actor; a disconnected custom Library must not be recreated.
                try await Task.detached(priority:.utility) {
                    if root == LibraryLocation.standardRoot {
                        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
                    } else {
                        guard try root.resourceValues(forKeys:[.isDirectoryKey]).isDirectory == true else { throw POSIXError(.ENOENT) }
                    }
                }.value
                NSWorkspace.shared.open(root)
            } catch { NSApp.presentError(error) }
        }
    }
}

/// Decorative and static: verbatim heights/fades from P2FirstRun-Desktop,
/// canvas 1794987301-5bc7. Four phrases, three pauses, then a fading tail.
private struct FirstRunWave: View {
    private static let bars: [(CGFloat,Double)] = [
        (7,1.00),(22,1.00),(12,1.00),(23,1.00),(22,1.00),(25,1.00),(30,1.00),(19,1.00),
        (30,1.00),(24,1.00),(14,1.00),(15,1.00),(22,1.00),(8,1.00),(10,1.00),(15,1.00),
        (25,1.00),(19,1.00),(23,1.00),(18,1.00),(19,0.93),(8,0.83),(6,0.78),(6,0.78),
        (8,0.83),(13,0.93),(14,1.00),(18,1.00),(17,1.00),(14,1.00),(19,1.00),(15,1.00),
        (11,1.00),(13,1.00),(11,1.00),(16,1.00),(22,1.00),(22,1.00),(16,1.00),(12,1.00),
        (13,1.00),(8,1.00),(15,1.00),(20,1.00),(15,1.00),(25,1.00),(18,1.00),(18,0.93),
        (6,0.78),(12,0.93),(19,1.00),(15,1.00),(15,1.00),(17,1.00),(16,1.00),(9,1.00),
        (17,1.00),(25,1.00),(27,1.00),(32,1.00),(19,1.00),(18,1.00),(35,1.00),(16,1.00),
        (16,1.00),(15,1.00),(22,1.00),(10,0.85),(6,0.78),(6,0.76),(8,0.81),(17,0.90),
        (22,0.87),(23,0.83),(19,0.80),(15,0.77),(8,0.73),(11,0.70),(6,0.67),(6,0.63),
        (6,0.60),(6,0.57),(6,0.53),(6,0.50),
    ]
    var body: some View {
        Canvas { context,size in
            // Preserve all phrases on narrow windows by reducing the gap only.
            let pitch = min(6,max(3,(size.width - 3) / CGFloat(Self.bars.count - 1)))
            for (index,level) in Self.bars.enumerated() {
                let bar = CGRect(x:CGFloat(index) * pitch,y:(size.height - level.0) / 2,width:3,height:level.0)
                context.fill(Path(roundedRect:bar,cornerRadius:1.5),with:.color(CassiniTheme.ink3.opacity(level.1)))
            }
        }.accessibilityHidden(true).allowsHitTesting(false)
    }
}
