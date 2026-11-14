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
    #endif
    @State private var toolbarWidth: CGFloat = 1120
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
        .font(.system(size: 13))
        .safeAreaInset(edge:.bottom,spacing:0) {
            UpdateReadyFooter(updates:updates)
        }
        .safeAreaInset(edge:.top,spacing:0) {
            CaptureFailureBanner(); trashFailure
            VStack(alignment:.leading,spacing:0) {
                ParakeetRecommendationView(afterFirst:true)
                ParakeetDefaultNotice()
            }.padding(.horizontal,18).background(CassiniTheme.paneGround)

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
        .frame(minWidth: 760, minHeight: 480)
        .navigationTitle(navigation.detail?.meeting.title ?? UXText.text("app.name"))
        .toolbar(removing: .title)
        .toolbar {
            if let detail = navigation.savedDetail {
                ToolbarItem(placement: .navigation) {
                    toolbarControl.padding(.trailing, 10)
                        .frame(width: 328, alignment: .trailing)
                }
                ToolbarItem(placement:.principal) {
                    if detail.compactHeader {
                        HStack(spacing: 8) {
                            Text(detail.meeting.title ?? UXText.text("library.untitled")).fontWeight(.semibold).lineLimit(1)
                            Text(store.format.previewSubtitle(detail.meeting.meetingTime, durationMs: detail.meeting.durationMs,
                                                              received: detail.meeting.state.origin == .received, transcribedOnAnotherDevice: detail.meeting.transcribedOnAnotherDevice))
                                .foregroundStyle(CassiniTheme.ink2).lineLimit(1)
                        }.accessibilityElement(children: .contain).accessibilityIdentifier("meeting-compact-header")
                    } else {
                        Color.clear.frame(width: 1, height: 1).accessibilityHidden(true)
                    }
                }
                if meetingShowsTranscriptionInToolbar(detail), let spec = meetingTranscriptionToolbarSpec(detail) {
                    ToolbarItem(placement:.primaryAction) {
                        LibraryToolbarAction(title:spec.title,label:spec.title,identifier:spec.identifier,style:.bordered,enabled:spec.enabled,action:spec.action)
                    }
                }
                ToolbarItem(placement:.primaryAction) {
                    HStack(spacing: 0) {
                        Button(UXText.text("common.exportEllipsis")) { exporter.show(detail.meeting) }
                            .disabled(!MeetingExportCoordinator.canExport(detail.meeting)).accessibilityIdentifier("meeting-export")
                        Divider().frame(height: 14).padding(.horizontal, 6)
                        Button {
                            store.selectedKey = detail.meeting.libraryKey
                            trash.move(detail.meeting, undoManager: undoManager ?? NSApp.keyWindow?.undoManager)
                        } label: { Image(systemName: "trash").frame(width: 22, height: 26) }
                            .disabled(!trash.canTrash(detail.meeting))
                            .help(UXText.text("common.moveToTrash")).accessibilityLabel(UXText.text("common.moveToTrash"))
                            .accessibilityIdentifier("meeting-trash")
                    }.buttonStyle(.borderless).foregroundStyle(CassiniTheme.ink).padding(.horizontal, 10).frame(height: 28)
                        .background(CassiniTheme.ink.opacity(0.1), in: Capsule())
                }
                ToolbarItem(placement:.primaryAction) {
                    LibraryToolbarAction(title:"",label:UXText.text("meeting.moreActions"),identifier:"meeting-more-actions",style:.more,menu:{
                        var entries:[LibraryToolbarAction.MenuEntry]=[
                            .init(title:UXText.text("details.menu"),identifier:"recording-details") {recordingDetails.show(detail.meeting)}]
                        if !meetingShowsTranscriptionInToolbar(detail), let spec = meetingTranscriptionToolbarSpec(detail) {
                            entries.insert(.init(title:spec.title,identifier:spec.identifier,enabled:spec.enabled,action:spec.action),at:0)
                        }
                        if detail.meeting.speakerMergeCount>0 {
                            entries.append(.init(title:UXText.text("meeting.undoMerge"),identifier:"undo-speaker-merge",enabled:rename.canEditSpeakers(detail.meeting)) {rename.undoSpeakerMerge(detail.meeting)})
                        }
                        entries.append(.init(title:UXText.text("common.moveToTrash"),identifier:"move-to-trash",enabled:trash.canTrash(detail.meeting)) {
                            store.selectedKey=detail.meeting.libraryKey
                            trash.move(detail.meeting,undoManager:undoManager ?? NSApp.keyWindow?.undoManager)
                        })
                        return LibraryToolbarAction.menu(entries)
                    }) { }
                }
            } else {
            ToolbarItem(placement: .navigation) {
                let emptyToolbar = showsFirstRun && !search.visible
                HStack(spacing: 0) {
                    toolbarControl
                        .padding(.trailing, emptyToolbar ? 0 : 10)
                        .frame(width: search.visible ? 388 : emptyToolbar ? nil : 328, alignment: emptyToolbar ? .leading : .trailing)
                    if search.visible || (!emptyToolbar && !recordingSelected) { toolbarTitle }
                }
            }
            if recordingSelected, let meeting = store.selected {
                ToolbarItem(placement:.principal) { Color.clear.frame(width:1) }
                ToolbarItem(placement:.primaryAction) {
                    LibraryToolbarAction(title:"",label:UXText.text("meeting.moreActions"),identifier:"recording-more-actions",style:.more,menu:{
                        LibraryToolbarAction.menu([.init(title:UXText.text("details.menu"),identifier:"recording-details") { recordingDetails.show(meeting) }])
                    }) { }
                }
            }
            }
        }
        .cassiniUnifiedToolbarChrome()
        .background(WindowAccessor { window in
            guard let window else { return }
            window.setAccessibilityIdentifier("cassini-library-window")
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
            if store.context.screenshot, ["meeting","export"].contains(LibraryLaunchContext.argument("-CassiniScreenshot") ?? ""), navigation.detail == nil,
               let meeting = store.meetings.first(where: { $0.title == (LibraryLaunchContext.argument("-CassiniScreenshot") == "export" ? "Budget review" : "Client call, Rossi & Partners") }) {
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
                sidebarDropWidth: showsFirstRun ? nil : 400,
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
    private var split: some View {
        let todayTitle = UXText.text("format.today")
        let firstGroupIsToday = store.groups.first?.title == todayTitle
        return HStack(spacing: 0) {
            VStack(spacing: 0) {
                ZStack {
                    List(selection: Binding(get: { store.selectedKeys }, set: {
                        let changed = $0 != store.selectedKeys
                        store.selectedKeys = $0
                        if changed, let window = NSApp.keyWindow,
                           LibraryKeyboardMenu.hasListFocus(in: window) {
                            openSelection(userInitiated: true)
                        }
                    })) {
                        if !importer.transientItems.isEmpty && !firstGroupIsToday {
                            Section {
                                ForEach(importer.transientItems) { item in
                                    transientImportRow(item)
                                }
                            } header: {
                                Text(todayTitle).font(.system(size: 11.5, weight: .bold)).foregroundStyle(CassiniTheme.ink2).textCase(nil)
                                    .accessibilityIdentifier("library-day-header-importing")
                            }
                        }
                        ForEach(Array(store.groups.enumerated()), id: \.element.id) { groupIndex, group in
                            Section {
                                if groupIndex == 0 && firstGroupIsToday {
                                    ForEach(importer.transientItems) { item in
                                        transientImportRow(item)
                                    }
                                }
                                ForEach(group.meetings, id: \.libraryKey) { meeting in
                                    row(meeting).tag(meeting.libraryKey)
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
                                            }
                                        })
                                        .contextMenu {
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
                                    .accessibilityIdentifier("library-day-header-" + (group.meetings.first?.libraryKey ?? "empty"))
                            }
                        }
                        if !store.meetings.isEmpty, store.meetings.allSatisfy({ $0.state.origin == .received }) {
                            Text(UXText.text("received.libraryHint")).font(.system(size:11.5)).foregroundStyle(CassiniTheme.ink2)
                                .listRowBackground(Color.clear).listRowSeparator(.hidden)
                        }
                    }
                    .listStyle(.sidebar)
                    .scrollContentBackground(.hidden)
                    .cassiniTopScrollEdge()
                    .opacity(dropState.dimsListContent ? 0.30 : 1.0)
                    .accessibilityLabel(UXText.text("library.listPane.a11y"))

                    LibraryDropListOverlay(state: dropState)
                }
                .cassiniPinnedTopBar {
                    LibrarySearchField(
                        text: $search.query,
                        large: false,
                        onClick: { search.open() },
                        onBegin: { search.open() },
                        onChange: { search.open() },
                        onCancel: { search.close() }
                    )
                    .frame(height: 28)
                    .padding(.horizontal, 10)
                    .padding(.top, 6)
                    .padding(.bottom, 8)
                }

                LibraryDropHintFooter(entered: dropState.showsWindowOutline)
            }
            .cassiniSidebarBackground()
            .frame(minWidth: 400, maxWidth: 400)
            CassiniColumnDivider()
            if let detail = navigation.savedDetail {
                MeetingView(model: detail, format: store.format).id(ObjectIdentifier(detail))
            } else if let meeting = store.selected, meeting.state.lifecycle != .saved {
                RecordingPageView(meeting:meeting,format:store.format).id(meeting.libraryKey)
            } else if navigation.loading { ProgressView().frame(maxWidth: .infinity) }
            else if store.selectedKeys.count > 1 {
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
            }
            else {
                Text(UXText.text("meeting.emptySelection")).foregroundStyle(CassiniTheme.ink2)
                    .frame(maxWidth: .infinity, maxHeight: .infinity).background(CassiniTheme.paneGround)
                    .accessibilityIdentifier("meeting-empty-selection")
            }
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
            } else { recordButton(big: false) }
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
                    CassiniBrandMark(height:compact ? FirstRunHeroMetrics.compactMark : FirstRunHeroMetrics.mark)
                    VStack(alignment:.leading,spacing:0) {
                        Text(UXText.text("firstRun.hero.title"))
                            .foregroundStyle(CassiniTheme.ink).accessibilityIdentifier("first-run-hero-title")
                        Text(UXText.text("firstRun.hero.subtitle"))
                            .foregroundStyle(CassiniTheme.ink3).accessibilityIdentifier("first-run-hero-subtitle")
                    }.font(.system(size:FirstRunHeroMetrics.headline,weight:.bold))
                        .lineLimit(1).minimumScaleFactor(0.45)
                        .frame(maxWidth:.infinity,alignment:.leading).accessibilityAddTraits(.isHeader)
                    if let line = RecordingOverview.libraryDiskLine {
                        Text(line).foregroundStyle(CassiniTheme.warningNotice)
                    }
                    HStack(spacing:FirstRunHeroMetrics.gap) {
                        recordButton(big:true).fixedSize()
                        FirstRunWave().frame(height:compact ? FirstRunHeroMetrics.compactMark : FirstRunHeroMetrics.mark)
                    }
                    VStack(alignment:.leading,spacing:10) {
                        Text(UXText.text("firstRun.body")).font(.system(size:13)).lineSpacing(4)
                            .fixedSize(horizontal:false,vertical:true)
                        Text(UXText.text("firstRun.shortcutHint",["shortcut":UXText.text("common.shortcut.record")]))
                            .font(.system(size:11.5))
                        HStack(alignment:.top,spacing:8) {
                            Image(systemName:"lock").accessibilityHidden(true)
                            if LibraryLocationModel.shared.location.primaryPath == LibraryLocation.standardRoot.path || store.context.screenshot {
                                Text(UXText.text("firstRun.footer"))
                            } else {
                                Text(UXText.text("settings.library.folder.title") + ": " + LibraryLocationModel.shared.displayPath)
                            }
                        }.font(.system(size:11.5)).fixedSize(horizontal:false,vertical:true)
                    }.foregroundStyle(CassiniTheme.ink2)
                }.padding(.horizontal,FirstRunHeroMetrics.horizontalPadding)
                    .padding(.vertical,compact ? FirstRunHeroMetrics.compactPadding : FirstRunHeroMetrics.padding)
                    .frame(maxWidth:FirstRunHeroMetrics.maxWidth + 2 * FirstRunHeroMetrics.horizontalPadding,alignment:.leading)
                    .frame(maxWidth:.infinity,minHeight:geometry.size.height,alignment:.center)
            }.accessibilityElement(children:.contain).accessibilityLabel(UXText.text("library.title"))
                .accessibilityAddTraits(.isHeader).accessibilityIdentifier("first-run-library")
        }.background(CassiniTheme.paneGround)
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
            HStack(spacing: big ? 10 : 7) {
                if saving {
                    ProgressView().controlSize(.small)
                } else {
                    Circle().fill(enabled ? CassiniTheme.onRecord : CassiniTheme.ink3).frame(width: big ? 12 : 9, height: big ? 12 : 9)
                }
                Text(title).fontWeight(.semibold)
            }.padding(.horizontal, big ? 22 : 14).frame(minWidth: big ? nil : 90).frame(height: big ? 44 : 34)
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

// L-27: desktop headline size is decided; the adaptable geometry stays here.
private enum FirstRunHeroMetrics {
    static let headline: CGFloat = 64
    static let maxWidth: CGFloat = 960
    static let horizontalPadding: CGFloat = 48
    static let gap: CGFloat = 24
    static let compactGap: CGFloat = 16
    static let mark: CGFloat = 64
    static let compactMark: CGFloat = 48
    static let padding: CGFloat = 32
    static let compactPadding: CGFloat = 24
    static let compactHeight: CGFloat = 600
}

/// Decorative and static: no microphone input, timer or motion to announce.
private struct FirstRunWave: View {
    private static let barWidth: CGFloat = 4
    private static let pitch: CGFloat = 8
    private static let maxBars = 96
    private static let fadeBars = 10
    private static let levels: [CGFloat] = [12,20,28,44,60,36,24,16,32,52,40,20,12,28,48,64,44,24,16]
    var body: some View {
        Canvas { context,size in
            let count = max(1,min(Self.maxBars,Int(size.width / Self.pitch)))
            let width = CGFloat(count - 1) * Self.pitch + Self.barWidth
            let start = (size.width - width) / 2
            for index in 0..<count {
                let height = min(size.height,Self.levels[index % Self.levels.count])
                let fade = min(1,Double(min(index,count - 1 - index)) / Double(Self.fadeBars))
                let bar = CGRect(x:start + CGFloat(index) * Self.pitch,y:(size.height - height) / 2,width:Self.barWidth,height:height)
                context.fill(Path(bar),with:.color(CassiniTokens.accent.opacity(fade)))
            }
        }.accessibilityHidden(true).allowsHitTesting(false)
    }
}
