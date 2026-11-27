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
    private static let narrowSidebarThreshold: CGFloat = 920
    private static var usesNativeSidebarSearch: Bool {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) { return true }
        #endif
        return false
    }
    @State private var toolbarWidth: CGFloat = 1120
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var userHidSidebar = false
    @State private var autoCollapsedSidebar = false
    @State private var floatingSidebarOpen = false
    @State private var contextMenuMeetingKey: String?
    @State private var sidebarSearchPresented = false
    @State private var sidebarWidth: CGFloat = 390
    private var isNarrowWindow: Bool { toolbarWidth < Self.narrowSidebarThreshold }
    private var showsEmbeddedSidebarSearch: Bool {
        !Self.usesNativeSidebarSearch || (isNarrowWindow && floatingSidebarOpen)
    }
    @State private var recordCoordinator = RecordCoordinator.shared
    @State private var recorder = RecordingController.shared
    @State private var companionSetup = CompanionSetup.shared
    @State private var rename = MeetingRenameCoordinator.shared
    @State private var dateTime = MeetingDateTimeCoordinator.shared
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
    private var rootSurface: some View {
        GeometryReader { geometry in
            Group {
                if navigation.loading { ProgressView() }
                else if showsFirstRun { firstRun }
                else { split }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
                .onAppear { handleWindowWidthChange(geometry.size.width) }
                .onChange(of: geometry.size.width) { _, width in handleWindowWidthChange(width) }
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
            handleSidebarSearchFocusRequest()
        }
        .onChange(of: columnVisibility) { _, newValue in
            if isNarrowWindow {
                if newValue != .detailOnly {
                    columnVisibility = .detailOnly
                    floatingSidebarOpen.toggle()
                }
            } else {
                autoCollapsedSidebar = false
                userHidSidebar = (newValue == .detailOnly)
            }
        }
        .onChange(of: search.query) { _, query in
            if !query.isEmpty {
                if !search.visible { search.open() }
                else { search.refresh() }
            } else if search.visible && !search.hasActiveFilters && !search.openedWithEmptyQuery {
                search.close()
            } else if search.visible {
                search.refresh()
            }
        }
        .onChange(of: search.visible) { _, visible in
            if !visible { sidebarSearchPresented = false }
        }
        .onChange(of: sidebarSearchPresented) { _, presented in
            if !presented && search.visible && search.query.isEmpty && !search.hasActiveFilters && !search.openedWithEmptyQuery {
                search.close()
            }
        }
    }

    private var chromeWrappedSurface: some View {
        rootSurface
            .frame(minWidth: 560, minHeight: 480)
            .modifier(LibraryWindowTitleModifier(
                savedDetail: navigation.savedDetail,
                showsFirstRun: showsFirstRun,
                searchVisible: search.visible,
                format: store.format
            ))
            .toolbar {
                if showsFirstRun {
                    ToolbarItem(placement:.automatic) { Spacer() }
                    ToolbarItem(id:"first-run-actions",placement:.primaryAction) { toolbarControl }
                }
            }
            .cassiniUnifiedToolbarChrome()
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
    }

    var body: some View {
        chromeWrappedSurface
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
        .sheet(isPresented:Binding(get:{ dateTime.showing },set:{ if !$0 { dateTime.cancel() } })) {
            MeetingDateTimeView()
        }
        .sheet(isPresented:$exporter.showing) { if let meeting = exporter.meeting { MeetingExportSheet(meeting:meeting) } }
        .sheet(isPresented:$recordingDetails.showing) { RecordingDetailsSheet() }
        .overlay(alignment:.bottom) { MeetingExportNotice() }
        .overlay(alignment:.bottom) { SpeakerEditFailureNotice() }
        .overlay(alignment:.bottom) { SpeakerEditToastView() }
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
        .onDisappear { rename.cancel(); dateTime.cancel(); sessionPlayback.stop(); navigation.back(); search.close() }
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
        Button(UXText.text("common.moveToTrash")) {
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
                .frame(minWidth: 260, idealWidth: 390, maxWidth: 420)
                .navigationSplitViewColumnWidth(min: 260, ideal: 390, max: 420)
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
            .frame(minWidth: 520)
            .toolbar {
                detailToolbar
            }
        }
        .modifier(ConditionalNativeSidebarSearch(
            enabled: Self.usesNativeSidebarSearch,
            query: $search.query,
            isPresented: $sidebarSearchPresented,
            prompt: UXText.text("search.field.placeholder")
        ))
        .overlay(alignment: .leading) {
            if isNarrowWindow && floatingSidebarOpen {
                floatingSidebarOverlay
            }
        }
    }

    private func handleSidebarSearchFocusRequest() {
        var presentation = LibrarySidebarSearchPresentation(
            floatingSidebarOpen: floatingSidebarOpen,
            userHidSidebar: userHidSidebar,
            showsSplitSidebar: columnVisibility != .detailOnly,
            sidebarSearchPresented: sidebarSearchPresented
        )
        let target = presentation.requestFocus(isNarrowWindow: isNarrowWindow)
        floatingSidebarOpen = presentation.floatingSidebarOpen
        userHidSidebar = presentation.userHidSidebar
        if presentation.showsSplitSidebar && !isNarrowWindow {
            columnVisibility = .all
        }
        sidebarSearchPresented = presentation.sidebarSearchPresented
        if target == .nativeSearchField {
            DispatchQueue.main.async {
                SidebarSearchFocus.focusLibrarySearchField()
            }
        }
    }

    private func handleWindowWidthChange(_ width: CGFloat) {
        let wasNarrow = toolbarWidth < Self.narrowSidebarThreshold
        toolbarWidth = width
        let nowNarrow = width < Self.narrowSidebarThreshold
        if nowNarrow {
            if columnVisibility != .detailOnly {
                autoCollapsedSidebar = true
                columnVisibility = .detailOnly
            }
        } else if wasNarrow {
            if floatingSidebarOpen {
                floatingSidebarOpen = false
                userHidSidebar = false
                autoCollapsedSidebar = false
                columnVisibility = .all
            } else if !userHidSidebar && autoCollapsedSidebar {
                autoCollapsedSidebar = false
                columnVisibility = .all
            }
        }
    }

    private var floatingSidebarOverlay: some View {
        let overlayWidth = min(390, max(280, toolbarWidth - 60))
        return ZStack(alignment: .leading) {
            Color.black.opacity(0.001)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { floatingSidebarOpen = false }
                .accessibilityHidden(true)
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Button {
                        floatingSidebarOpen = false
                    } label: {
                        Image(systemName: "sidebar.left")
                            .font(.system(size: 14))
                            .foregroundStyle(CassiniTheme.ink)
                            .frame(width: 24, height: 24)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(UXText.text("library.listPane.a11y"))
                    .accessibilityIdentifier("floating-sidebar-toggle")
                    Spacer(minLength: 0)
                    sidebarImportButton
                    if showsLiveToolbarPill {
                        liveRecordingToolbarControl(height: 24)
                    } else {
                        sidebarRecordButton(height: 24)
                    }
                }
                .padding(.leading, 76)
                .padding(.trailing, 10)
                .padding(.top, 10)
                .padding(.bottom, 6)
                sidebarColumn
            }
            .frame(width: overlayWidth)
            .frame(maxHeight: .infinity)
            .cassiniSidebarBackground()
            .overlay(alignment: .trailing) {
                Rectangle().fill(CassiniTheme.cardStroke).frame(width: 1)
            }
            .shadow(color: CassiniTheme.shadow, radius: 18, x: 4, y: 0)
            .ignoresSafeArea(edges: .top)
            .onExitCommand { floatingSidebarOpen = false }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("floating-sidebar")
        }
    }

    private var showsLiveToolbarPill: Bool {
        RecordingOverview.active || RecordingOverview.saving
            || store.meetings.contains(where: { $0.state.lifecycle == .recording })
    }

    private var sidebarImportButton: some View {
        let enabled = !LibraryMoveCoordinator.shared.busy && LibraryLocationModel.shared.available
        return Button {
            LegacyOpening.chooseDocuments()
        } label: {
            ImportTrayIcon(size: 13, strokeWidth: 1.8)
                .foregroundStyle(enabled ? CassiniTheme.ink : CassiniTheme.ink3)
                .frame(width: 24, height: 24)
                .modifier(SidebarGlassCircleModifier())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(UXText.text("import.action"))
        .accessibilityLabel(UXText.text("import.action"))
        .accessibilityIdentifier("toolbar-import")
    }

    @ToolbarContentBuilder
    private var sidebarToolbar: some ToolbarContent {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            ToolbarItem(placement: .primaryAction) {
                sidebarImportButton
            }
            .sharedBackgroundVisibility(.hidden)
            ToolbarSpacer(.fixed, placement: .primaryAction)
            ToolbarItem(placement: .primaryAction) {
                if showsLiveToolbarPill {
                    liveRecordingToolbarControl(height: 24)
                } else {
                    sidebarRecordButton(height: 24)
                }
            }
            .sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(placement: .primaryAction) {
                sidebarImportButton
            }
            ToolbarItem(placement: .primaryAction) {
                if showsLiveToolbarPill {
                    liveRecordingToolbarControl(height: 24)
                } else {
                    sidebarRecordButton(height: 24)
                }
            }
        }
        #else
        ToolbarItem(placement: .primaryAction) {
            sidebarImportButton
        }
        ToolbarItem(placement: .primaryAction) {
            if showsLiveToolbarPill {
                liveRecordingToolbarControl(height: 24)
            } else {
                sidebarRecordButton(height: 24)
            }
        }
        #endif
    }

    @ViewBuilder
    private func liveRecordingToolbarControl(height: CGFloat) -> some View {
        let compact = height <= 24
        let innerHeight = max(18, height - 6)
        if RecordingOverview.active, let started = RecordingOverview.startedAt {
            LiveRecordingPill(started: started, microphone: RecordingOverview.levels["microphone", default: 0], output: RecordingOverview.levels["output", default: 0], height: height)
        } else if RecordingOverview.saving {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(UXText.text("states.badge.saving"))
                    .font(.system(size: compact ? 12 : 13, weight: .semibold))
                    .foregroundStyle(CassiniTheme.ink2)
            }
            .padding(.horizontal, compact ? 10 : 14)
            .frame(height: height)
            .background(CassiniTheme.neutralPillFill, in: Capsule())
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("toolbar-saving")
        } else if let live = store.meetings.first(where: { $0.state.lifecycle == .recording }) {
            HStack(spacing: 6) {
                Circle().fill(CassiniTheme.recordInk).frame(width: compact ? 7 : 8, height: compact ? 7 : 8)
                Text(LibraryFormat.liveBadge(live.state.liveMs ?? 0))
                    .font(.system(size: compact ? 12 : 13, weight: .semibold))
                    .monospacedDigit().foregroundStyle(CassiniTheme.recordInk)
                Text(UXText.text("common.stop"))
                    .font(.system(size: compact ? 11 : 12, weight: .semibold))
                    .foregroundStyle(CassiniTheme.onRecord)
                    .padding(.horizontal, compact ? 8 : 12)
                    .frame(height: innerHeight)
                    .background(CassiniTheme.record, in: Capsule())
            }
            .fixedSize()
            .padding(.leading, compact ? 8 : 12)
            .padding(.trailing, 3)
            .frame(height: height)
            .background(CassiniTheme.recordTint, in: Capsule())
        }
    }

    private func sidebarRecordButton(height: CGFloat) -> some View {
        let compact = height <= 24
        let enabled = RecordingOverview.canStart
        let title = UXText.text("common.record")
        return Button {
            sessionPlayback.stop()
            RecordCoordinator.shared.request(parent: store.context.root)
        } label: {
            HStack(spacing: compact ? 6 : 7) {
                Circle()
                    .fill(enabled ? CassiniTheme.onRecord : CassiniTheme.ink3)
                    .frame(width: compact ? 7 : 8, height: compact ? 7 : 8)
                Text(title)
                    .font(.system(size: compact ? 12.5 : 13, weight: .semibold))
                    .foregroundStyle(enabled ? CassiniTheme.onRecord : CassiniTheme.ink3)
            }
            .padding(.horizontal, compact ? 10 : 12)
            .frame(height: height)
            .background(enabled ? CassiniTheme.record : CassiniTheme.chipFill, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(title)
        .accessibilityLabel(title)
        .accessibilityIdentifier("toolbar-record")
    }

    private var displayedSearchPreviewMeeting: LibraryMeeting? {
        guard search.visible, let hit = search.selected else { return nil }
        return search.meeting(hit)
    }

    private var detailToolbarTarget: LibraryDetailToolbarTarget {
        LibraryDetailToolbarTarget.resolve(
            searchVisible: search.visible,
            searchPreviewMeeting: displayedSearchPreviewMeeting,
            savedDetailMeeting: navigation.savedDetail?.meeting,
            recordingSelected: recordingSelected,
            selectedMeeting: store.selected
        )
    }

    @ViewBuilder
    private func detailMeetingActionButtons(for meeting: LibraryMeeting, allowTrash: Bool, exportDisabled: Bool) -> some View {
        let starred = store.isStarred(meeting)
        Button {
            store.toggleStar(meeting)
        } label: {
            Image(systemName: starred ? "star.fill" : "star")
                .foregroundStyle(starred ? CassiniTheme.accentInk : CassiniTheme.ink)
        }
        .help(UXText.text(starred ? "meeting.unstar" : "meeting.star"))
        .accessibilityLabel(UXText.text(starred ? "meeting.unstar" : "meeting.star"))
        .accessibilityIdentifier("meeting-star")

        Button {
            exporter.show(meeting)
        } label: {
            Image(systemName: "square.and.arrow.up")
        }
        .disabled(exportDisabled || !MeetingExportCoordinator.canExport(meeting))
        .help(UXText.text("common.exportEllipsis"))
        .accessibilityLabel(UXText.text("common.exportEllipsis"))
        .accessibilityIdentifier("meeting-export")

        if allowTrash {
            Button {
                store.selectedKey = meeting.libraryKey
                trash.move(meeting, undoManager: undoManager ?? NSApp.keyWindow?.undoManager)
            } label: {
                Image(systemName: "trash")
            }
            .disabled(!trash.canTrash(meeting))
            .help(UXText.text("common.moveToTrash"))
            .accessibilityLabel(UXText.text("common.moveToTrash"))
            .accessibilityIdentifier("meeting-trash")
        }
    }

    @ToolbarContentBuilder
    private var detailToolbar: some ToolbarContent {
        let target = detailToolbarTarget
        detailSidebarCollapsedToolbarItem
        detailCompactHeaderToolbarItem(for: target)
        detailToolbarSpacer
        detailFindToolbarItem(for: target)
        detailActionToolbarItem(for: target)
    }

    @ToolbarContentBuilder
    private var detailSidebarCollapsedToolbarItem: some ToolbarContent {
        if columnVisibility == .detailOnly {
            #if compiler(>=6.2)
            if #available(macOS 26.0, *) {
                ToolbarItem(placement: .navigation) {
                    if showsLiveToolbarPill {
                        liveRecordingToolbarControl(height: 32)
                    } else {
                        sidebarRecordButton(height: 32)
                    }
                }
                .sharedBackgroundVisibility(.hidden)
            } else {
                ToolbarItem(placement: .navigation) {
                    if showsLiveToolbarPill {
                        liveRecordingToolbarControl(height: 32)
                    } else {
                        sidebarRecordButton(height: 32)
                    }
                }
            }
            #else
            ToolbarItem(placement: .navigation) {
                if showsLiveToolbarPill {
                    liveRecordingToolbarControl(height: 32)
                } else {
                    sidebarRecordButton(height: 32)
                }
            }
            #endif
        }
    }

    @ToolbarContentBuilder
    private func detailCompactHeaderToolbarItem(for target: LibraryDetailToolbarTarget) -> some ToolbarContent {
        if target.showsCompactHeader, let detail = navigation.savedDetail, detail.compactHeader {
            let title = detail.meeting.title ?? UXText.text("library.untitled")
            let subtitle = store.format.previewSubtitle(
                detail.meeting.meetingTime,
                durationMs: detail.meeting.durationMs,
                received: detail.meeting.state.origin == .received,
                transcribedOnAnotherDevice: detail.meeting.transcribedOnAnotherDevice
            )
            let titleMaxWidth: CGFloat = toolbarWidth < 860 ? 180 : 320
            let leadingInset: CGFloat = columnVisibility == .detailOnly ? 0 : 22
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
                    .padding(.leading, leadingInset)
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
                    .padding(.leading, leadingInset)
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
                .padding(.leading, leadingInset)
            }
            #endif
        }
    }

    @ToolbarContentBuilder
    private var detailToolbarSpacer: some ToolbarContent {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            ToolbarSpacer(.flexible, placement: .primaryAction)
        } else {
            ToolbarItem(placement: .automatic) { Spacer() }
        }
        #else
        ToolbarItem(placement: .automatic) { Spacer() }
        #endif
    }

    @ToolbarContentBuilder
    private func detailFindToolbarItem(for target: LibraryDetailToolbarTarget) -> some ToolbarContent {
        if target.showsFindAction, let detail = navigation.savedDetail {
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
        }
    }

    private func recordingMoreActionsButton(for meeting: LibraryMeeting) -> some View {
        let starTitle = UXText.text(store.isStarred(meeting) ? "meeting.unstar" : "meeting.star")
        let detailsTitle = UXText.text("details.menu")
        return LibraryToolbarAction(
            title: "",
            label: UXText.text("meeting.moreActions"),
            identifier: "recording-more-actions",
            style: .more,
            menu: {
                let entries: [LibraryToolbarAction.MenuEntry] = [
                    LibraryToolbarAction.MenuEntry(title: starTitle, identifier: "recording-star") {
                        store.toggleStar(meeting)
                    },
                    LibraryToolbarAction.MenuEntry(title: detailsTitle, identifier: "recording-details") {
                        recordingDetails.show(meeting)
                    }
                ]
                return LibraryToolbarAction.menu(entries)
            }
        ) {}
    }

    private func detailMeetingActionConfig(for target: LibraryDetailToolbarTarget) -> (meeting: LibraryMeeting, allowTrash: Bool, exportDisabled: Bool)? {
        switch target {
        case .savedDetail(let meeting):
            return (meeting, true, false)
        case .searchPreview(let meeting):
            return (meeting, false, search.searching)
        case .recording, .none:
            return nil
        }
    }

    private func recordingActionMeeting(for target: LibraryDetailToolbarTarget) -> LibraryMeeting? {
        if case .recording(let meeting) = target { return meeting }
        return nil
    }

    @ToolbarContentBuilder
    private func detailActionToolbarItem(for target: LibraryDetailToolbarTarget) -> some ToolbarContent {
        if let config = detailMeetingActionConfig(for: target) {
            ToolbarItemGroup(placement: .primaryAction) {
                detailMeetingActionButtons(
                    for: config.meeting,
                    allowTrash: config.allowTrash,
                    exportDisabled: config.exportDisabled
                )
            }
        }
        if let meeting = recordingActionMeeting(for: target) {
            ToolbarItem(placement: .primaryAction) {
                recordingMoreActionsButton(for: meeting)
            }
        }
    }

    private var sidebarColumn: some View {
        VStack(spacing: 0) {
            if showsEmbeddedSidebarSearch {
                LibrarySearchField(
                    text: $search.query,
                    large: false,
                    focusRequest: search.focusRequest,
                    onChange: {
                        if !search.query.isEmpty {
                            if !search.visible { search.open() }
                            else { search.refresh() }
                        } else if search.visible && !search.hasActiveFilters && !search.openedWithEmptyQuery {
                            search.close()
                        } else if search.visible {
                            search.refresh()
                        }
                    },
                    onCancel: { search.close() }
                )
                .frame(height: 28)
                .padding(.horizontal, 10)
                .padding(.top, 6)
                .padding(.bottom, 6)
            }
            if search.visible {
                LibrarySearchSidebarContent(
                    format: store.format,
                    showEmbeddedField: false,
                    onPickResult: {
                        var presentation = LibrarySidebarSearchPresentation(
                            floatingSidebarOpen: floatingSidebarOpen,
                            userHidSidebar: userHidSidebar,
                            showsSplitSidebar: columnVisibility != .detailOnly,
                            sidebarSearchPresented: sidebarSearchPresented
                        )
                        presentation.didPickSearchResult()
                        floatingSidebarOpen = presentation.floatingSidebarOpen
                    }
                )
            } else {
                libraryListSidebarColumn
            }
        }
    }

    private var libraryListSidebarColumn: some View {
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
                .tint(nil)
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
                                    .padding(.leading, 20)
                                    .padding(.trailing, 10)
                                    .padding(.top, 10)
                                    .padding(.bottom, 4)
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
                                                if floatingSidebarOpen { floatingSidebarOpen = false }
                                                LibraryKeyboardMenu.focusList()
                                                DispatchQueue.main.async { LibraryKeyboardMenu.focusList() }
                                            }
                                        })
                                        .contextMenu {
                                            Button(UXText.text(store.isStarred(meeting) ? "meeting.unstar" : "meeting.star")) { store.toggleStar(meeting) }
                                                .accessibilityIdentifier("library-star")
                                                .onAppear { contextMenuMeetingKey = meeting.libraryKey }
                                                .onDisappear { if contextMenuMeetingKey == meeting.libraryKey { contextMenuMeetingKey = nil } }
                                            Button(UXText.text("meeting.renameEllipsis")) { store.selectedKey = meeting.libraryKey; rename.show(meeting) }
                                                .disabled(store.selectedKeys.count > 1 || !rename.canRename(meeting)).accessibilityIdentifier("library-rename")
                                            Button(UXText.text("meeting.setDateTimeEllipsis")) { store.selectedKey = meeting.libraryKey; dateTime.show(meeting) }
                                                .disabled(store.selectedKeys.count > 1 || !dateTime.canSetDateTime(meeting)).accessibilityIdentifier("library-set-date-time")
                                            Button(UXText.text("common.exportEllipsis")) { store.selectedKey = meeting.libraryKey; exporter.show(meeting) }
                                                .disabled(store.selectedKeys.count > 1 || !MeetingExportCoordinator.canExport(meeting))
                                                .onAppear {
                                                    if !store.selectedKeys.contains(meeting.libraryKey) {
                                                        store.selectedKey = meeting.libraryKey
                                                    }
                                                }
                                            if store.selectedKeys.count > 1 {
                                                Button(UXText.text("export.zip.selected")) { bulkExporter.exportSelected() }
                                                    .disabled(!bulkExporter.canExportSelected)
                                                    .accessibilityIdentifier("library-export-selected-zip")
                                            }
                                            Button(UXText.text("details.menu")) { store.selectedKey = meeting.libraryKey; recordingDetails.show(meeting) }
                                                .disabled(store.selectedKeys.count > 1)
                                                .accessibilityIdentifier("library-recording-details")
                                            if store.selectedKeys.count <= 1 && trash.canTrash(meeting) { Divider(); trashButton(meeting) }
                                        }
                                        .listRowSeparator(.hidden)
                                        .listRowBackground(Color.clear)
                                        .listRowInsets(EdgeInsets(top: 3, leading: 10, bottom: 3, trailing: 10))
                                        .accessibilityIdentifier("meeting-" + meeting.libraryKey)
                                }
                            } header: {
                                Text(group.title).font(.system(size: 11.5, weight: .bold)).foregroundStyle(CassiniTheme.ink2).textCase(nil)
                                    .padding(.leading, 20)
                                    .padding(.trailing, 10)
                                    .padding(.top, 10)
                                    .padding(.bottom, 4)
                                    .accessibilityIdentifier("library-day-header-" + (group.meetings.first?.libraryKey ?? "empty"))
                            }
                        }
                        if !store.meetings.isEmpty, store.meetings.allSatisfy({ $0.state.origin == .received }) {
                            Text(UXText.text("received.libraryHint")).font(.system(size: 11.5)).foregroundStyle(CassiniTheme.ink2)
                                .padding(.horizontal, 10)
                                .listRowBackground(Color.clear).listRowSeparator(.hidden)
                        }
                    }
                    .listStyle(.plain)
                    .contentMargins(.horizontal, 0, for: .scrollContent)
                    .scrollContentBackground(.hidden)
                    .modifier(SidebarBottomScrollEdgeModifier())
                    .accessibilityLabel(UXText.text("library.listPane.a11y"))
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        LibraryDropHintFooter(entered: dropState.showsWindowOutline)
                    }
                    .opacity(dropState.dimsListContent ? 0.30 : 1.0)

                    LibraryDropListOverlay(state: dropState)
                }
                .onChange(of: importScrollTarget, initial: true) { _, target in
                    if let target {
                        proxy.scrollTo(target, anchor: .center)
                        store.consumeImportedSelection(target)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var detailColumn: some View {
        if search.visible, let hit = search.selected, let meeting = search.meeting(hit) {
            LibrarySearchPreviewPane(hit: hit, meeting: meeting, format: store.format)
        } else if let detail = navigation.savedDetail {
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
        return MeetingCard(isSelected: selected, isContextMenuTarget: contextMenuMeetingKey == meeting.libraryKey) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(meeting.title ?? UXText.text("library.untitled"))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(CassiniTheme.ink)
                        .lineLimit(1)
                    Spacer(minLength: 2)
                    if store.isStarred(meeting) {
                        Image(systemName:"star.fill")
                            .font(.system(size: 10.5))
                            .foregroundStyle(CassiniTheme.accentInk)
                            .accessibilityLabel(UXText.text("library.row.starred.a11y"))
                            .accessibilityIdentifier("library-starred-" + meeting.libraryKey)
                    }
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
                            .layoutPriority(1)
                        if let trailingMeta {
                            Text(trailingMeta)
                                .foregroundStyle(CassiniTheme.ink2)
                                .lineLimit(1)
                                .truncationMode(.tail)
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
}

private struct LibraryWindowTitleModifier: ViewModifier {
    let savedDetail: MeetingDetailModel?
    let showsFirstRun: Bool
    let searchVisible: Bool
    let format: LibraryFormat

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

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            InlineEditableTitle(
                title: title,
                fontSize: 13,
                weight: .semibold,
                singleLine: true,
                canRename: canRename,
                identifier: "meeting-window-title",
                editorIdentifier: "meeting-window-title-editor",
                maxWidth: maxWidth,
                editing: $editing,
                onCommit: onCommit
            )
            if !editing {
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(CassiniTheme.secondaryInk)
                    .lineLimit(1)
                    .accessibilityIdentifier("meeting-window-subtitle")
            }
        }
        .frame(maxWidth: maxWidth, alignment: .leading)
        .onChange(of: title) { _, _ in editing = false }
        .onChange(of: canRename) { _, allowed in if !allowed { editing = false } }
    }
}

private struct SidebarGlassCircleModifier: ViewModifier {
    func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: .circle)
        } else {
            content.background(CassiniTheme.chipFill, in: Circle())
        }
        #else
        content.background(CassiniTheme.chipFill, in: Circle())
        #endif
    }
}

private struct SidebarBottomScrollEdgeModifier: ViewModifier {
    func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            content.scrollEdgeEffectStyle(.soft, for: .bottom)
        } else {
            content
        }
        #else
        content
        #endif
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

private struct ConditionalNativeSidebarSearch: ViewModifier {
    let enabled: Bool
    @Binding var query: String
    @Binding var isPresented: Bool
    let prompt: String

    func body(content: Content) -> some View {
        if enabled {
            content.searchable(
                text: $query,
                isPresented: $isPresented,
                placement: .sidebar,
                prompt: prompt
            )
        } else {
            content
        }
    }
}
