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
    /// D-1199 item 7 (L-108): docked and floating sidebars share one `sidebarColumn`
    /// and one `LibrarySearchField` component so both presentations match identically.
    private static let usesNativeSidebarSearch = false
    @State private var toolbarWidth: CGFloat = 1120
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var userHidSidebar = false
    @State private var autoCollapsedSidebar = false
    @State private var floatingSidebarOpen = false
    @State private var contextMenuMeetingKey: String?
    @State private var sidebarHasContentBelow = false
    @State private var sidebarSearchPresented = false
    @State private var sidebarWidth: CGFloat = 390
    private var isNarrowWindow: Bool { toolbarWidth < Self.narrowSidebarThreshold }
    private var isFloatingSidebarVisible: Bool { isNarrowWindow && floatingSidebarOpen }
    private var showsEmbeddedSidebarSearch: Bool { true }
    @State private var recordCoordinator = RecordCoordinator.shared
    @State private var recorder = RecordingController.shared
    @State private var companionSetup = CompanionSetup.shared
    @State private var rename = MeetingRenameCoordinator.shared
    @State private var dateTime = MeetingDateTimeCoordinator.shared
    @State private var updates = ApplicationUpdates.shared
    @State private var speechModels = SpeechModelController.shared
    @State private var importer = LibraryImportCoordinator.shared
    @State private var dropState: LibraryDropState = .idle
    @Environment(\.scenePhase) private var scenePhase
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
                else if showsFirstRun {
                    LibraryFirstRunView(
                        root: store.context.root,
                        screenshot: store.context.screenshot,
                        dropState: dropState
                    ) {
                        sessionPlayback.stop()
                        RecordCoordinator.shared.request(parent: store.context.root)
                    }
                }
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
            let noticeBackground = showsFirstRun ? CassiniTheme.surface : CassiniTheme.paneGround
            trashFailure
            ParakeetRecommendationView(afterFirst: true, horizontalPadding: 18, background: noticeBackground)
            ParakeetDefaultNotice(horizontalPadding: 18, background: noticeBackground)

            if !store.context.screenshot && companionSetup.showLibraryState && showsSplit && !search.visible {
                BrowserConnectionStateView(identifier:"library-browser-status",presenter:.library)
                    .font(.system(size:11.5)).foregroundStyle(CassiniTheme.ink2).padding(.horizontal,18).padding(.vertical,8)
                    .background(CassiniTheme.paneGround, ignoresSafeAreaEdges: [])
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
                WindowClickAwayFocusController.attach(to: window) { endedControl in
                    if endedControl is NSSearchField,
                       search.visible,
                       search.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                       !search.hasActiveFilters {
                        search.close()
                    }
                }
                SpeakerEditorChrome.update(window,visible:rename.presentation == .speakers)
                #if DEBUG
                if store.loaded { ScreenshotFixture.prepareLibrary(window) }
                #endif
            })
            .disabled(rename.presentation == .speakers)
            .allowsHitTesting(!(isNarrowWindow && floatingSidebarOpen))
            .accessibilityHidden(rename.presentation == .speakers || (isNarrowWindow && floatingSidebarOpen))
    }

    var body: some View {
        chromeWrappedSurface
        .toolbar {
            if isFloatingSidebarVisible {
                #if compiler(>=6.2)
                if #available(macOS 26.0, *) {
                    ToolbarItem(placement: .navigation) {
                        sidebarToolbarActions
                    }
                    .sharedBackgroundVisibility(.hidden)
                } else {
                    ToolbarItem(placement: .navigation) {
                        sidebarToolbarActions
                    }
                }
                #else
                ToolbarItem(placement: .navigation) {
                    sidebarToolbarActions
                }
                #endif
            }
        }
        .overlay(alignment: .leading) {
            if isNarrowWindow && floatingSidebarOpen {
                floatingSidebarOverlay
            }
        }
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
        .onReceive(NotificationCenter.default.publisher(for: .cassiniToggleSidebar)) { _ in
            guard !showsFirstRun else { return }
            if isNarrowWindow {
                floatingSidebarOpen.toggle()
            } else {
                columnVisibility = columnVisibility == .detailOnly ? .all : .detailOnly
            }
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
    @ViewBuilder private var trashFailure: some View {
        if let meeting = trash.failure, (navigation.detail?.meeting.libraryKey ?? store.selectedKey) == meeting.libraryKey {
            HStack(spacing:12) {
                Text(UXText.text(trash.unsupported ? "meeting.trashUnsupported" : "meeting.trashFailed"))
                Spacer()
                if trash.unsupported {
                    Button(UXText.text("meeting.showInFiles")) { NSWorkspace.shared.activateFileViewerSelecting([meeting.folder]) }
                        .buttonStyle(PageSecondaryButtonStyle())
                } else {
                    Button(UXText.text("common.tryAgain")) { trash.move(meeting,undoManager:undoManager) }
                        .buttonStyle(PageSecondaryButtonStyle())
                        .disabled(!trash.canTrash(meeting))
                }
            }.padding(12).foregroundStyle(CassiniTheme.warnInk).background(CassiniTheme.warnTint, ignoresSafeAreaEdges: [])
                .accessibilityIdentifier("trash-failure")
        }
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
            sidebarColumn(isFloating: false)
                .cassiniSidebarBackground()
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
        return HStack(spacing: 0) {
            VStack(spacing: 0) {
                sidebarColumn(isFloating: true)
                    .padding(.top, 44)
            }
            .frame(width: overlayWidth)
            .frame(maxHeight: .infinity)
            .modifier(FloatingSidebarGlassModifier(cornerRadius: 16))
            .shadow(color: CassiniTheme.shadow, radius: 18, x: 0, y: 6)
            .padding(8)
            .ignoresSafeArea(edges: .top)
            .onExitCommand { floatingSidebarOpen = false }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("floating-sidebar")

            Color.black.opacity(0.001)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { floatingSidebarOpen = false }
                .accessibilityHidden(true)
        }
        .disabled(rename.presentation == .speakers)
        .accessibilityHidden(rename.presentation == .speakers)
    }

    private var showsLiveToolbarPill: Bool {
        RecordingOverview.active || RecordingOverview.saving
            || store.meetings.contains(where: { $0.state.lifecycle == .recording })
    }

    private var sidebarToolbarActions: some View {
        HStack(spacing: 8) {
            sidebarImportButton
            if showsLiveToolbarPill {
                liveRecordingToolbarControl(height: 24)
            } else {
                sidebarRecordButton(height: 24)
            }
        }
        .fixedSize()
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
        if columnVisibility != .detailOnly {
            #if compiler(>=6.2)
            if #available(macOS 26.0, *) {
                ToolbarItem(placement: .primaryAction) {
                    sidebarToolbarActions
                }
                .sharedBackgroundVisibility(.hidden)
            } else {
                ToolbarItem(placement: .primaryAction) {
                    sidebarToolbarActions
                }
            }
            #else
            ToolbarItem(placement: .primaryAction) {
                sidebarToolbarActions
            }
            #endif
        }
    }

    @ViewBuilder
    private func liveRecordingToolbarControl(height: CGFloat) -> some View {
        let compact = height <= 24
        let innerHeight = max(18, height - 6)
        if RecordingOverview.active {
            LiveRecordingPill(
                started: RecordingOverview.startedAt ?? Date(),
                microphone: RecordingOverview.levels["microphone", default: 0],
                output: RecordingOverview.levels["output", default: 0],
                height: height
            )
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
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("toolbar-live-pill")
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
            .frame(minWidth: 80, minHeight: height, maxHeight: height)
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
        if !isFloatingSidebarVisible {
            let target = detailToolbarTarget
            detailSidebarCollapsedToolbarItem
            detailCompactHeaderToolbarItem(for: target)
            detailToolbarSpacer
            detailFindToolbarItem(for: target)
            detailActionToolbarItem(for: target)
        }
    }

    private var collapsedSidebarRecordControl: some View {
        HStack(spacing: 0) {
            if showsLiveToolbarPill {
                liveRecordingToolbarControl(height: 32)
            } else {
                sidebarRecordButton(height: 32)
            }
            Color.clear.frame(width: 0, height: 0).accessibilityHidden(true)
        }
        .accessibilityElement(children: .contain)
    }

    @ToolbarContentBuilder
    private var detailSidebarCollapsedToolbarItem: some ToolbarContent {
        if columnVisibility == .detailOnly {
            #if compiler(>=6.2)
            if #available(macOS 26.0, *) {
                ToolbarItem(placement: .navigation) {
                    collapsedSidebarRecordControl
                }
                .sharedBackgroundVisibility(.hidden)
            } else {
                ToolbarItem(placement: .navigation) {
                    collapsedSidebarRecordControl
                }
            }
            #else
            ToolbarItem(placement: .navigation) {
                collapsedSidebarRecordControl
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

    private func sidebarColumn(isFloating: Bool) -> some View {
        let activeFloating = isNarrowWindow && floatingSidebarOpen
        return VStack(spacing: 0) {
            if showsEmbeddedSidebarSearch {
                LibrarySearchField(
                    text: $search.query,
                    large: false,
                    focusRequest: isFloating == activeFloating ? search.focusRequest : 0,
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
                    onCancel: {
                        let hadQueryOrSearch = !search.query.isEmpty || search.visible
                        search.close()
                        if isFloating && !hadQueryOrSearch {
                            floatingSidebarOpen = false
                        }
                    }
                )
                .frame(height: 26)
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

    private func dayHeaderRow(title: String, identifier: String) -> some View {
        Text(title)
            .font(.system(size: 11.5, weight: .bold))
            .foregroundStyle(CassiniTheme.ink2)
            .textCase(nil)
            .accessibilityIdentifier(identifier)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 10)
            .padding(.trailing, 10)
            .padding(.top, 10)
            .padding(.bottom, 6)
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 0, leading: 10, bottom: 0, trailing: 10))
            .selectionDisabled(true)
    }

    private var libraryListSidebarColumn: some View {
        let todayTitle = UXText.text("format.today")
        let firstGroupIsToday = store.groups.first?.title == todayTitle
        return VStack(spacing: 0) {
            HStack {
                LibraryFilterSegmentedControl(selection: $store.preferences.filter)
                    .fixedSize()
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
                            dayHeaderRow(title: todayTitle, identifier: "library-day-header-importing")
                            ForEach(importer.transientItems) { item in
                                transientImportRow(item)
                            }
                        }
                        if store.preferences.filter == .starred && store.visibleMeetings.isEmpty {
                            Text(UXText.text("library.starred.empty"))
                                .foregroundStyle(CassiniTheme.ink2)
                                .listRowBackground(Color.clear).listRowSeparator(.hidden)
                                .selectionDisabled(true)
                                .accessibilityIdentifier("library-starred-empty")
                        }
                        ForEach(Array(store.groups.enumerated()), id: \.element.id) { groupIndex, group in
                            dayHeaderRow(
                                title: group.title,
                                identifier: "library-day-header-" + (group.meetings.first?.libraryKey ?? "empty")
                            )
                            if store.preferences.filter == .all && groupIndex == 0 && firstGroupIsToday {
                                ForEach(importer.transientItems) { item in
                                    transientImportRow(item)
                                }
                            }
                            ForEach(group.meetings, id: \.libraryKey) { meeting in
                                row(meeting)
                                    .accessibilityIdentifier("meeting-" + meeting.libraryKey)
                                    .tag(meeting.libraryKey).id(meeting.libraryKey)
                                    .background {
                                        LibraryRowOpenAnchor(
                                            rowKey: meeting.libraryKey,
                                            open: {
                                                guard !LibraryMoveCoordinator.shared.busy else { return }
                                                readTranscript(meeting)
                                            },
                                            isEnabled: rename.presentation != .speakers,
                                            menuAccessibilityLabel: UXText.text("meeting.moreActions"),
                                            menuAccessibilityIdentifier: "meeting-menu-" + meeting.libraryKey,
                                            buildContextMenu: {
                                                LibraryKeyboardMenu.buildContextMenu(
                                                    for: meeting,
                                                    trash: trash,
                                                    undo: undoManager,
                                                    forKeyboard: false
                                                )
                                            },
                                            onContextMenuOpenChanged: { open in
                                                if open {
                                                    contextMenuMeetingKey = meeting.libraryKey
                                                } else if contextMenuMeetingKey == meeting.libraryKey {
                                                    contextMenuMeetingKey = nil
                                                }
                                            }
                                        )
                                        .accessibilityIdentifier("meeting-menu-" + meeting.libraryKey)
                                        if store.primarySelectedKey == meeting.libraryKey { LibraryMenuAnchor() }
                                    }
                                    .accessibilityAction(named: UXText.text("meeting.moreActions")) {
                                        LibraryRowOpenAnchor.performShowMenu(forKey: meeting.libraryKey)
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
                                    .listRowSeparator(.hidden)
                                    .listRowBackground(Color.clear)
                                    .listRowInsets(EdgeInsets(top: 3, leading: 10, bottom: 3, trailing: 10))
                            }
                        }
                        if !store.meetings.isEmpty, store.meetings.allSatisfy({ $0.state.origin == .received }) {
                            Text(UXText.text("received.libraryHint")).font(.system(size: 11.5)).foregroundStyle(CassiniTheme.ink2)
                                .padding(.horizontal, 10)
                                .listRowBackground(Color.clear).listRowSeparator(.hidden)
                                .selectionDisabled(true)
                        }
                    }
                    .listStyle(.plain)
                    .contentMargins(.horizontal, 0, for: .scrollContent)
                    .scrollContentBackground(.hidden)
                    .onScrollGeometryChange(for: Bool.self) { geometry in
                        geometry.contentSize.height - geometry.visibleRect.maxY > 1
                    } action: { _, hasBelow in
                        if sidebarHasContentBelow != hasBelow {
                            sidebarHasContentBelow = hasBelow
                        }
                    }
                    .modifier(SidebarBottomScrollEdgeModifier(hasContentBelow: sidebarHasContentBelow))
                    .accessibilityLabel(UXText.text("library.listPane.a11y"))
                    .modifier(SidebarDropFooterModifier {
                        LibraryDropHintFooter(entered: dropState.showsWindowOutline)
                    })
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
            VStack(spacing: 0) {
                if CaptureCollection.shared.hasFailure {
                    CaptureFailureBanner()
                        .padding(.horizontal, 44)
                        .padding(.top, 12)
                }
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(CassiniTheme.paneGround)
        } else if store.selectedKeys.count > 1 {
            VStack(spacing: 0) {
                if CaptureCollection.shared.hasFailure {
                    CaptureFailureBanner()
                        .padding(.horizontal, 44)
                        .padding(.top, 12)
                }
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
            VStack(spacing: 0) {
                if CaptureCollection.shared.hasFailure {
                    CaptureFailureBanner()
                        .padding(.horizontal, 44)
                        .padding(.top, 12)
                }
                Text(UXText.text("meeting.emptySelection")).foregroundStyle(CassiniTheme.ink2)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityIdentifier("meeting-empty-selection")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(CassiniTheme.paneGround)
        }
    }
    private func transientImportRow(_ item: LibraryImportCoordinator.TransientItem) -> some View {
        LibraryTransientImportRowView(
            item: item,
            format: store.format,
            isAnimatingBadges: !store.context.screenshot && scenePhase == .active,
            onDismiss: { importer.dismissTransientItem(item.id) }
        )
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
            } else if !showsFirstRun || search.visible {
                let title = UXText.text("common.record")
                LibraryToolbarAction(title: title, label: title, identifier: "toolbar-record", style: .record, enabled: RecordingOverview.canStart) {
                    sessionPlayback.stop(); RecordCoordinator.shared.request(parent: store.context.root)
                }.frame(minWidth: 90).fixedSize(horizontal: true, vertical: false)
            }
        }.accessibilityElement(children: .contain)
    }
    private func row(_ meeting: LibraryMeeting) -> some View {
        LibraryMeetingRowView(
            meeting: meeting,
            isSelected: store.selectedKeys.contains(meeting.libraryKey),
            isContextMenuTarget: contextMenuMeetingKey == meeting.libraryKey,
            isStarred: store.isStarred(meeting),
            format: store.format,
            isAnimatingBadges: !store.context.screenshot && scenePhase == .active
        )
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
