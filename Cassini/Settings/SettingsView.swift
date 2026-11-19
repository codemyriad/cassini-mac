// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import AppKit
import Observation
import CassiniLibrary

enum SettingsTab: String, CaseIterable { case recording, transcription, library, browser, updates
    var title: String {
        UXText.text(self == .recording ? "settings.tab.recording" : self == .transcription ? "settings.tab.transcription" : self == .library ? "settings.tab.library" : self == .browser ? "settings.tab.browserCompanion" : "settings.updates.title")
    }
    var icon: String { self == .recording ? "mic" : self == .transcription ? "text.alignleft" : self == .library ? "folder" : self == .browser ? "macwindow" : "arrow.triangle.2.circlepath" }
}
@MainActor @Observable final class SettingsNavigation {
    static let shared = SettingsNavigation()
    var tab = SettingsTab.recording
    var capturingShortcut = false
    var savedVoices = false
    @ObservationIgnored var open: (() -> Void)? = { ApplicationWindows.preferences(); NSApp.activate(ignoringOtherApps:true) }
}
struct CassiniSettingsView: View {
    @State private var navigation = SettingsNavigation.shared
    @State private var companion = CompanionSetup.shared
    var body: some View {
        TabView(selection:$navigation.tab) {
            SettingsRecordingView().tabItem { Label(SettingsTab.recording.title,systemImage:SettingsTab.recording.icon) }.tag(SettingsTab.recording)
            NavigationStack {
                SettingsTranscriptionView().navigationDestination(isPresented:$navigation.savedVoices) { SavedVoicesView() }
            }.tabItem { Label(SettingsTab.transcription.title,systemImage:SettingsTab.transcription.icon) }.tag(SettingsTab.transcription)
            SettingsLibraryView().tabItem { Label(SettingsTab.library.title,systemImage:SettingsTab.library.icon) }.tag(SettingsTab.library)
            SettingsBrowserView().tabItem { Label(SettingsTab.browser.title,systemImage:SettingsTab.browser.icon) }.tag(SettingsTab.browser)
            SettingsUpdatesView().tabItem { Label(SettingsTab.updates.title,systemImage:SettingsTab.updates.icon) }.tag(SettingsTab.updates)
        }.frame(width:700,height:520)
            .preferredColorScheme(LibraryLaunchContext.screenshotDark ? .dark : (LibraryLaunchContext.current.screenshot ? .light : nil))
            .font(.system(size:13)).accessibilityLabel(UXText.text("settings.pages.a11y"))
            .background(WindowAccessor { window in
                guard let window else { return }
                window.title = UXText.text("settings.title"); window.setAccessibilityIdentifier("cassini-settings-window")
                #if DEBUG
                SettingsFixture.prepare(window)
                #endif
            })
            .sheet(isPresented:Binding(get:{ companion.presenter == .settings },set:{ if !$0 { companion.close() } })) {
                CompanionSetupView()
            }
            .overlay(alignment:.bottom) { TransferStatusBanner() }
    }
}
private struct SettingsUpdatesView: View {
    @State private var updates = ApplicationUpdates.shared
    var body: some View {
        SettingsPage(footnote: "settings.updates.privacy") {
            SettingsGroup("settings.updates.title") {
                HStack(alignment:.center,spacing:10) {
                    Text(UXText.text("settings.updates.automatic.phase2"))
                    Spacer()
                    Toggle(UXText.text("settings.updates.automatic.phase2"),isOn:$updates.automaticChecks)
                        .labelsHidden().toggleStyle(.switch).disabled(!updates.available)
                        .accessibilityIdentifier("settings-automatic-updates")
                }.padding(10).frame(minHeight:40)
                Divider().padding(.horizontal,10)
                HStack(alignment:.center,spacing:10) {
                    HStack(alignment:.firstTextBaseline,spacing:8) {
                        Text(UXText.text("about.nameVersion",["version":AboutPanel.version]))
                        if updates.isUpToDate {
                            Text(UXText.text("settings.updates.upToDate"))
                                .font(.system(size:11.5)).foregroundStyle(CassiniTheme.ink2)
                        }
                    }
                    Spacer()
                    Button(UXText.text("settings.updates.checkNow")) { updates.checkForUpdates() }
                        .disabled(!updates.canCheckForUpdates).accessibilityIdentifier("settings-check-updates")
                }.padding(10).frame(minHeight:40)
            }
        }
    }
}
private struct SettingsRecordingView: View {
    @AppStorage("CassiniSkipRecordFirst",store:RecordingPreferences.defaults) private var skipFirst = false
    @AppStorage("CassiniShowMenuBar",store:RecordingPreferences.defaults) private var showMenuBar = true
    @State private var shortcut = RecordingRuntime.shared.shortcut
    @State private var navigation = SettingsNavigation.shared
    @State private var test = TestRecordingController.shared
    @State private var captures = CaptureCollection.shared
    @State private var setup = CompanionSetup.shared
    private var autoRecordAvailable: Bool { captures.connected || captures.autoRecord }
    var body: some View {
        SettingsPage {
            SettingsGroup("settings.recording.group.starting") {
                HStack(alignment:.center,spacing:10) {
                    Text(UXText.text("settings.recording.shortcut.title"))
                    Spacer()
                    Text(shortcut.choice.glyph)
                        .font(.system(size:12,weight:.semibold,design:.monospaced))
                        .padding(.horizontal,7).padding(.vertical,2)
                        .background(CassiniTheme.ink.opacity(0.07),in:RoundedRectangle(cornerRadius:5))
                        .fixedSize().accessibilityIdentifier("settings-shortcut")
                    Button(UXText.text("settings.recording.changeShortcut")) { navigation.capturingShortcut = true }
                        .accessibilityIdentifier("settings-change-shortcut")
                }.padding(10).frame(minHeight:40)
                Divider().padding(.horizontal,10)
                HStack(alignment:.top,spacing:10) {
                    SettingsDescription("settings.recording.firstRecord.title", "settings.recording.firstRecord.subtitle").accessibilityHidden(true)
                    Spacer()
                    Toggle(UXText.text("settings.recording.firstRecord.title"),isOn:Binding(get:{ !skipFirst },set:{ skipFirst = !$0 }))
                        .labelsHidden().toggleStyle(.switch).accessibilityIdentifier("settings-explain-recording")
                }.padding(10).frame(minHeight:40)
            }
            SettingsGroup("settings.recording.group.browser", headerTrailing: {
                if captures.connected {
                    HStack(spacing:6) {
                        Circle().fill(CassiniTheme.success).frame(width:7,height:7).accessibilityHidden(true)
                        Text(setup.connectedStatusText)
                    }
                    .font(.system(size:12)).foregroundStyle(CassiniTheme.ink2)
                    .accessibilityIdentifier("settings-recording-browser-status")
                } else {
                    HStack(spacing:4) {
                        Text(UXText.text("settings.recording.group.browser.subtitle"))
                            .foregroundStyle(CassiniTheme.ink2)
                        Text("·").foregroundStyle(CassiniTheme.ink2).accessibilityHidden(true)
                        Button(UXText.text("settings.recording.browser.setUp")) { navigation.tab = .browser }
                            .buttonStyle(.plain)
                            .foregroundStyle(CassiniTheme.accentInk)
                            .fontWeight(.medium)
                            .underline()
                            .accessibilityIdentifier("settings-browser-set-up")
                    }
                    .font(.system(size:12))
                    .accessibilityIdentifier("settings-recording-browser-status")
                }
            }) {
                HStack(alignment:.top,spacing:10) {
                    VStack(alignment:.leading,spacing:2) {
                        Text(UXText.text("settings.recording.autoRecord.title"))
                            .opacity(autoRecordAvailable ? 1 : 0.55)
                        Text(UXText.text("settings.recording.autoRecord.subtitleShort"))
                            .font(.system(size:11.5)).foregroundStyle(CassiniTheme.ink2)
                            .fixedSize(horizontal:false,vertical:true)
                            .opacity(autoRecordAvailable ? 1 : 0.55)
                        Toggle(UXText.text("settings.general.menuBar"),isOn:$showMenuBar)
                            .toggleStyle(.checkbox)
                            .disabled(!captures.autoRecord)
                            .padding(.top,8)
                            .accessibilityIdentifier("settings-show-menu-bar")
                    }
                    Spacer()
                    Toggle(UXText.text("settings.recording.autoRecord.title"),isOn:Binding(get:{ captures.autoRecord },set:{ enabled in
                        Task { do { try await captures.setAutoRecord(enabled) } catch { NSApp.presentError(error) } }
                    })).labelsHidden().toggleStyle(.switch)
                        .disabled(!autoRecordAvailable)
                        .accessibilityIdentifier("settings-auto-record")
                }.padding(10).frame(minHeight:40)
            }
            HStack(alignment:.center,spacing:10) {
                VStack(alignment:.leading,spacing:2) {
                    Text(UXText.text("test.action")).fontWeight(.semibold)
                    Text(UXText.text("settings.recording.test.descriptionShort"))
                        .font(.system(size:12)).foregroundStyle(CassiniTheme.ink2)
                        .fixedSize(horizontal:false,vertical:true)
                }
                Spacer()
                Button(UXText.text("settings.recording.test.button")) { test.presented = true }
                    .disabled(!test.canStart).accessibilityIdentifier("settings-test-recording")
            }.padding(.leading,4).padding(.trailing,11)
        }.sheet(isPresented:$test.presented) { TestRecordingView() }
        .sheet(isPresented:$navigation.capturingShortcut) {
            VStack(alignment:.leading,spacing:18) {
                Text(UXText.text("settings.recording.shortcut.title")).font(.system(size:17,weight:.bold))
                ShortcutCaptureView { candidate in
                    let code = shortcut.change(to:candidate)
                    if code == noErr { navigation.capturingShortcut = false }
                    else { NSApp.presentError(NSError(domain:NSOSStatusErrorDomain,code:Int(code))) }
                } cancel:{ navigation.capturingShortcut = false }
                    .frame(height:60).background(CassiniTheme.chipFill,in:RoundedRectangle(cornerRadius:8))
                    .overlay { Text(shortcut.choice.glyph).font(.system(size:20,design:.monospaced)).foregroundStyle(CassiniTheme.ink2).allowsHitTesting(false) }
                    .accessibilityLabel(UXText.text("settings.recording.shortcut.title"))
                HStack { Spacer(); Button(UXText.text("common.cancel")) { navigation.capturingShortcut = false }.keyboardShortcut(.cancelAction) }
            }.padding(26).frame(width:440)
        }
    }
}
private struct SettingsLibraryView: View {
    @State private var location = LibraryLocationModel.shared
    @State private var move = LibraryMoveCoordinator.shared
    @State private var stats: String?
    @State private var bulkExporter = BulkZipExportCoordinator.shared
    var body: some View {
        SettingsPage {
            SettingsGroup("settings.library.folder.title",
                          subtitle:"settings.library.folder.descriptionShort",
                          caption:"settings.library.deleted.caption") {
                VStack(alignment:.leading,spacing:10) {
                    HStack(alignment:.top,spacing:10) {
                        VStack(alignment:.leading,spacing:2) {
                            Text(LibraryStore.shared.context.screenshot ? LibraryLocationModel.display(LibraryLocation.standardRoot) : location.displayPath)
                                .textSelection(.enabled).accessibilityIdentifier("settings-library-path")
                            if let stats {
                                Text(stats).font(.system(size:11.5)).foregroundStyle(CassiniTheme.ink2)
                                    .accessibilityIdentifier("settings-library-stats")
                            }
                        }
                        Spacer()
                        HStack(spacing:8) {
                            Button(UXText.text("settings.library.show")) {
                                let root = location.roots[0]
                                Task {
                                    do {
                                        try await Task.detached(priority:.utility) {
                                            if root == LibraryLocation.standardRoot {
                                                try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
                                            } else {
                                                guard try root.resourceValues(forKeys:[.isDirectoryKey]).isDirectory == true else { throw POSIXError(.ENOENT) }
                                            }
                                        }.value
                                        NSWorkspace.shared.activateFileViewerSelecting([root])
                                    } catch { NSApp.presentError(error) }
                                }
                            }
                            Button(UXText.text("settings.library.move")) { move.choose(parent:NSApp.keyWindow) }
                                .disabled(!move.canChoose).accessibilityIdentifier("settings-move-library")
                        }
                    }
                    if move.busy {
                        HStack(spacing:6) {
                            ProgressView().controlSize(.small)
                            Text(UXText.text("settings.library.move.moving")).font(.system(size:11.5)).foregroundStyle(CassiniTheme.ink2)
                        }
                    }
                    if let problem = location.problem {
                        Text(problem).font(.system(size:11.5)).foregroundStyle(CassiniTheme.warnInk).fixedSize(horizontal:false,vertical:true)
                    }
                    if !move.busy, move.waitingCount > 0 {
                        Text(UXText.text("settings.library.move.waiting",["n":String(move.waitingCount)]))
                            .font(.system(size:11.5)).foregroundStyle(CassiniTheme.ink2).fixedSize(horizontal:false,vertical:true)
                    }
                    ForEach(move.failures) { group in
                        VStack(alignment:.leading,spacing:8) {
                            Text(UXText.text("settings.library.move.failed",["n":String(group.names.count),"folder":LibraryLocationModel.display(group.root)]))
                                .font(.system(size:11.5)).foregroundStyle(CassiniTheme.warnInk).fixedSize(horizontal:false,vertical:true)
                            Button(UXText.text("common.tryAgain")) { move.retry(root:group.root) }
                                .disabled(move.busy).accessibilityIdentifier("settings-retry-move")
                        }
                    }
                }.padding(10).frame(minHeight:40,alignment:.leading)
            }
            SettingsGroup("settings.library.group.keepingCopy",
                          caption:"settings.library.backUp.caption") {
                HStack(alignment:.top,spacing:10) {
                    SettingsDescription("settings.library.zip.title", "settings.library.zip.subtitle")
                    Spacer()
                    Button(UXText.text("common.exportEllipsis")) { bulkExporter.exportAll() }
                        .disabled(!bulkExporter.canExportAll).accessibilityIdentifier("settings-export-all-zip")
                }.padding(10).frame(minHeight:40)
            }
        }.task(id: LibraryStore.shared.revision) {
            let revision = LibraryStore.shared.revision
            let folders = LibraryStore.shared.meetings.map(\.folder)
            let worker = Task.detached(priority:.utility) { () -> Int64? in
                var total: Int64 = 0
                for folder in folders {
                    guard let files = FileManager.default.enumerator(at:folder,includingPropertiesForKeys:[.isRegularFileKey,.fileSizeKey,.isSymbolicLinkKey]) else { return nil }
                    for case let file as URL in files {
                        guard !Task.isCancelled else { return nil }
                        if let values = try? file.resourceValues(forKeys:[.isRegularFileKey,.fileSizeKey,.isSymbolicLinkKey]), values.isRegularFile == true, values.isSymbolicLink != true {
                            total += Int64(values.fileSize ?? 0)
                        }
                    }
                }
                return total
            }
            let bytes = await withTaskCancellationHandler(operation:{ await worker.value },onCancel:{ worker.cancel() })
            guard !Task.isCancelled else { return }
            stats = bytes.map { UXText.text("settings.library.stats",["meetings":UXText.text("library.meetingCount",["n":String(folders.count)]),"size":LibraryFormat.size(bytes:$0)]) }
            #if DEBUG
            SettingsRenderReadiness.shared.libraryRevision = revision
            #endif
        }
    }
}
private struct SettingsBrowserView: View {
    @State private var setup = CompanionSetup.shared
    @State private var captures = CaptureCollection.shared
    @State private var showingRemoveHowTo = false
    private var statusText: String {
        if captures.connected { return setup.connectedStatusText }
        if !captures.needsUpdate && !setup.working && !setup.failed && !setup.noBrowser {
            return UXText.text("settings.browser.status.notSetUp")
        }
        return setup.stateLine
    }
    private var addButtonLabel: String {
        if CompanionSetup.storeListingPublic, !setup.selectedBrowserName.isEmpty {
            return UXText.text("companion.addTo",["browser":setup.selectedBrowserName])
        }
        return setup.addLabel
    }
    private var hasHealthNotices: Bool {
        captures.companionHealth.peers.contains { peer in
            let outdated = CompanionSetup.bundledCompanionVersion.map { peer.diagnostics.isOlder(than:$0) } ?? false
            return peer.diagnostics.filesMissing || outdated || !peer.supportsMultiStream || !peer.reloadTabs.isEmpty || peer.automaticUnverified
        }
    }
    var body: some View {
        SettingsPage(footnote: "companion.privacy") {
            SettingsGroup("settings.browser.heading", subtitle:"settings.browser.body") {
                VStack(alignment:.leading,spacing:0) {
                    HStack(alignment:.top,spacing:10) {
                        VStack(alignment:.leading,spacing:2) {
                            HStack(spacing:7) {
                                Circle()
                                    .fill(captures.connected ? CassiniTheme.success : CassiniTheme.error)
                                    .frame(width:8,height:8)
                                    .accessibilityHidden(true)
                                Text(statusText)
                                    .fixedSize(horizontal:false,vertical:true)
                                    .accessibilityIdentifier("settings-browser-status")
                            }
                            Text(UXText.text("companion.worksWith"))
                                .font(.system(size:11.5)).foregroundStyle(CassiniTheme.ink2)
                                .fixedSize(horizontal:false,vertical:true)
                        }
                        Spacer(minLength:8)
                        if captures.connected {
                            Button(UXText.text("settings.browser.remove")) {
                                setup.openExtensionsPageForConnectedBrowser()
                                showingRemoveHowTo = true
                            }.accessibilityIdentifier("settings-remove-companion")
                        } else if setup.failed {
                            Button(UXText.text("common.tryAgain")) { setup.trigger() }
                                .accessibilityIdentifier("browser-try-again")
                        } else if !setup.working || setup.noBrowser {
                            Button(addButtonLabel) { setup.add(from:.settings) }
                                .disabled(!setup.canAdd)
                                .accessibilityIdentifier("browser-add")
                        }
                    }
                    if hasHealthNotices {
                        BrowserCompanionHealthView(presenter:.settings).padding(.top,10)
                    }
                }.padding(10).frame(minHeight:40,alignment:.leading)
            }
        }.sheet(isPresented:$showingRemoveHowTo) {
            VStack(alignment:.leading,spacing:16) {
                Text(UXText.text("settings.tab.browserCompanion")).font(.system(size:17,weight:.bold))
                // Provisional draft string (D107): kept in one place so copy updates are trivial.
                Text(UXText.text("settings.browser.remove.howTo"))
                    .foregroundStyle(CassiniTheme.ink2)
                    .fixedSize(horizontal:false,vertical:true)
                    .accessibilityIdentifier("settings-remove-companion-howto")
                if let copied = setup.copiedNotice {
                    Text(copied).font(.system(size:11.5)).foregroundStyle(CassiniTheme.ink2)
                        .fixedSize(horizontal:false,vertical:true)
                }
                HStack {
                    Spacer()
                    Button(UXText.text("common.done")) { showingRemoveHowTo = false }
                        .keyboardShortcut(.defaultAction)
                        .accessibilityIdentifier("settings-remove-companion-done")
                }
            }.padding(24).frame(width:420)
        }
    }
}

private struct SettingsTranscriptionView: View {
    @State private var voicePreferences = VoicePreferences.shared
    @State private var models = SpeechModelController.shared
    @State private var weightSize = ""
    @State private var downloadBytes: Int64 = 0
    var body: some View {
        SettingsPage(footnote: "settings.transcription.footnote") {
            VStack(alignment:.leading,spacing:0) {
                VStack(alignment:.leading,spacing:4) {
                    Text(UXText.text("settings.transcription.speech.heading")).fontWeight(.semibold)
                    Text(UXText.text("models.keepTranscript"))
                        .font(.system(size:12)).foregroundStyle(CassiniTheme.ink2)
                        .fixedSize(horizontal:false,vertical:true)
                }.padding(.horizontal,4).padding(.bottom,10)
                ParakeetRecommendationView(afterFirst:false)
                ParakeetDefaultNotice()
                VStack(spacing:0) {
                    HStack(alignment:.top,spacing:12) {
                        SpeechRadio(selected:!models.usesParakeet,label:UXText.text("models.whistle.name")) { models.chooseParakeet(false) }
                            .frame(width:15,height:15).padding(.top,1).accessibilityIdentifier("settings-whistle-radio")
                        VStack(alignment:.leading,spacing:2) {
                            HStack(alignment:.firstTextBaseline,spacing:6) {
                                Text(UXText.text("models.whistle.name")).fontWeight(.semibold)
                                Text(weightSize).font(.system(size:11.5)).foregroundStyle(CassiniTheme.ink2)
                            }
                            Text(UXText.text("models.whistle.description.short"))
                                .font(.system(size:11.5)).foregroundStyle(CassiniTheme.ink2)
                                .fixedSize(horizontal:false,vertical:true)
                            if !models.usesParakeet {
                                Text(UXText.text("models.status.inUse"))
                                    .font(.system(size:11.5,weight:.medium)).foregroundStyle(CassiniTheme.success)
                            }
                        }
                        Spacer(minLength:4)
                        Text(UXText.text("models.builtIn"))
                            .font(.system(size:11.5)).foregroundStyle(CassiniTheme.ink2).padding(.top,2)
                    }.padding(.horizontal,12).padding(.vertical,10).frame(maxWidth:.infinity,alignment:.leading)
                        .background(!models.usesParakeet ? CassiniTheme.accentTint.opacity(0.6) : Color.clear)
                        .accessibilityElement(children:.contain).accessibilityIdentifier("settings-whistle-row")
                    Divider().padding(.horizontal,10)
                    HStack(alignment:.top,spacing:12) {
                        SpeechRadio(selected:models.usesParakeet,label:UXText.text("models.parakeetUltra.name")) { models.chooseParakeet(true) }
                            .frame(width:15,height:15).padding(.top,1).disabled(!models.downloaded)
                            .accessibilityIdentifier("settings-parakeet-radio")
                        VStack(alignment:.leading,spacing:2) {
                            HStack(alignment:.firstTextBaseline,spacing:6) {
                                Text(UXText.text("models.parakeetUltra.name")).fontWeight(.semibold)
                                if !models.downloaded {
                                    Text(UXText.text("format.size.download",["size":LibraryFormat.size(bytes:downloadBytes)]))
                                        .font(.system(size:11.5)).foregroundStyle(CassiniTheme.ink2)
                                }
                            }
                            Text(UXText.text("models.parakeetUltra.description.short"))
                                .font(.system(size:11.5)).foregroundStyle(CassiniTheme.ink2)
                                .fixedSize(horizontal:false,vertical:true)
                            if let progress = models.progress {
                                ProgressView(value:progress).accessibilityLabel(UXText.text("models.downloading.a11y",["model":UXText.text("models.parakeetUltra.name")]))
                                Text(UXText.text("models.status.downloading",["percent":String(Int(progress * 100))])).font(.system(size:11)).foregroundStyle(CassiniTheme.ink2)
                            } else if models.downloaded {
                                Text(UXText.text(models.usesParakeet ? "models.status.inUse" : "models.status.downloaded"))
                                    .font(.system(size:11.5,weight:.medium)).foregroundStyle(models.usesParakeet ? CassiniTheme.success : CassiniTheme.ink2)
                            }
                        }
                        Spacer(minLength:4)
                        if models.progress != nil {
                            Button(UXText.text("common.cancel")) { models.cancelDownload() }.accessibilityIdentifier("settings-cancel-model")
                        } else if models.downloaded {
                            Button(UXText.text("models.remove")) { models.remove() }.disabled(models.busy).accessibilityIdentifier("settings-remove-parakeet")
                        } else {
                            Button(UXText.text(models.failedDownload ? "common.retry" : "models.download")) { models.download() }
                                .disabled(models.busy).accessibilityIdentifier("settings-download-parakeet")
                        }
                    }.padding(.horizontal,12).padding(.vertical,10).frame(maxWidth:.infinity,alignment:.leading)
                        .background(models.usesParakeet ? CassiniTheme.accentTint.opacity(0.6) : Color.clear)
                        .accessibilityElement(children:.contain).accessibilityIdentifier("settings-parakeet-row")
                }.background(CassiniTheme.surface,in:RoundedRectangle(cornerRadius:10))
                    .clipShape(RoundedRectangle(cornerRadius:10))
                    .overlay(RoundedRectangle(cornerRadius:10).stroke(CassiniTheme.lineSoft,lineWidth:1))
                if let message = models.message {
                    Text(message).font(.system(size:12)).foregroundStyle(models.failedDownload ? CassiniTheme.warnInk : CassiniTheme.ink2)
                        .fixedSize(horizontal:false,vertical:true).padding(.top,6).padding(.horizontal,4)
                        .accessibilityIdentifier("settings-model-message")
                }
            }.accessibilityElement(children:.contain).accessibilityLabel(UXText.text("settings.transcription.speech.a11y"))
                .accessibilityIdentifier(models.recommendationReady ? "settings-speech-models-ready" : "settings-speech-models-loading")
            SettingsGroup("common.speakers", subtitle:"settings.transcription.speakers.description") {
                SavedVoiceModelRow().padding(10).frame(minHeight:40)
                Divider().padding(.horizontal,10)
                HStack(alignment:.top,spacing:10) {
                    SettingsDescription("voices.rememberDefault.title", "voices.rememberDefault.subtitle").accessibilityHidden(true)
                    Spacer()
                    Toggle(UXText.text("voices.rememberDefault.title"),isOn:$voicePreferences.remember)
                        .labelsHidden().toggleStyle(.switch).accessibilityIdentifier("settings-remember-voices")
                }.padding(10).frame(minHeight:40)
                Divider().padding(.horizontal,10)
                SavedVoicesSettingsRow().padding(10).frame(minHeight:40)
            }
        }.task {
            let url = Bundle.main.url(forResource:"whistle",withExtension:"cact",subdirectory:"Whistle")
            let bytes = await Task.detached(priority:.utility) {
                url.flatMap { try? $0.resourceValues(forKeys:[.fileSizeKey]).fileSize }
            }.value
            if let bytes { weightSize = LibraryFormat.size(bytes:Int64(bytes)) }
            downloadBytes = await Task.detached(priority:.utility) { SpeechModelController.downloadBytes }.value
            await models.refresh()
            await SavedVoicesController.shared.refresh()
            #if DEBUG
            SettingsRenderReadiness.shared.transcription = true
            #endif
        }
    }
}
private struct SettingsPage<Content: View>: View {
    let footnote: String?
    @ViewBuilder let content: Content
    init(footnote: String? = nil, @ViewBuilder content: () -> Content) {
        self.footnote = footnote
        self.content = content()
    }
    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(alignment:.leading,spacing:24) {
                    content
                    if let footnote {
                        Spacer(minLength:0)
                        SettingsPrivacyFootnote(footnote)
                    }
                }
                .padding(.horizontal,28).padding(.vertical,20)
                .frame(maxWidth:.infinity,minHeight:proxy.size.height,alignment:.topLeading)
            }
        }.background(CassiniTheme.windowGround)
    }
}
private struct SettingsPrivacyFootnote: View {
    let key: String
    init(_ key: String) { self.key = key }
    var body: some View {
        HStack(spacing:6) {
            Image(systemName:"lock")
                .font(.system(size:12,weight:.medium))
                .foregroundStyle(CassiniTheme.accentInk)
                .accessibilityHidden(true)
            Text(UXText.text(key))
                .font(.system(size:12))
                .foregroundStyle(CassiniTheme.ink2)
                .fixedSize(horizontal:false,vertical:true)
        }
        .frame(maxWidth:.infinity,alignment:.center)
        .padding(.bottom,6)
        .accessibilityIdentifier("settings-privacy-footnote")
    }
}
private struct ShortcutCaptureView: NSViewRepresentable {
    let receive: (RecordingHotKey) -> Void
    let cancel: () -> Void
    func makeNSView(context: Context) -> Capture {
        let view = Capture(); view.receive = receive; view.cancel = cancel
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }; return view
    }
    func updateNSView(_ view: Capture, context: Context) { view.receive = receive; view.cancel = cancel }
    final class Capture: NSView {
        var receive: ((RecordingHotKey) -> Void)?; var cancel: (() -> Void)?
        override var acceptsFirstResponder: Bool { true }
        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            guard window?.firstResponder === self else { return false }; keyDown(with:event); return true
        }
        override func keyDown(with event: NSEvent) {
            if event.keyCode == 53 { cancel?(); return }
            guard let choice = RecordingHotKey(event:event) else { NSSound.beep(); return }
            receive?(choice)
        }
    }
}

private struct SpeechRadio: NSViewRepresentable {
    let selected: Bool
    let label: String
    let action: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(action) }
    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(title:"",target:context.coordinator,action:#selector(Coordinator.select))
        button.setButtonType(.radio); button.setAccessibilityLabel(label); return button
    }
    func updateNSView(_ view: NSButton, context: Context) {
        view.state = selected ? .on : .off; view.isEnabled = context.environment.isEnabled; context.coordinator.action = action
    }
    final class Coordinator: NSObject {
        var action: () -> Void
        init(_ action: @escaping () -> Void) { self.action = action }
        @objc func select() { action() }
    }
}

struct SettingsDescription: View {
    let title: String, subtitle: String
    init(_ title: String, _ subtitle: String) { self.title = title; self.subtitle = subtitle }
    var body: some View {
        VStack(alignment:.leading,spacing:2) {
            Text(UXText.text(title))
            Text(UXText.text(subtitle)).font(.system(size:11.5)).foregroundStyle(CassiniTheme.ink2)
                .fixedSize(horizontal:false,vertical:true)
        }
    }
}
struct SettingsGroup<HeaderTrailing: View, Content: View>: View {
    let title: String
    let subtitle: String?
    let caption: String?
    @ViewBuilder let headerTrailing: HeaderTrailing
    @ViewBuilder let content: Content
    init(_ title: String,
         subtitle: String? = nil,
         caption: String? = nil,
         @ViewBuilder headerTrailing: () -> HeaderTrailing,
         @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.caption = caption
        self.headerTrailing = headerTrailing()
        self.content = content()
    }
    var body: some View {
        VStack(alignment:.leading,spacing:0) {
            VStack(alignment:.leading,spacing:4) {
                HStack(alignment:.firstTextBaseline,spacing:12) {
                    Text(UXText.text(title)).fontWeight(.semibold)
                    Spacer()
                    headerTrailing
                }
                if let subtitle {
                    Text(UXText.text(subtitle))
                        .font(.system(size:12)).foregroundStyle(CassiniTheme.ink2)
                        .fixedSize(horizontal:false,vertical:true)
                }
            }.padding(.horizontal,4).padding(.bottom,10)
            VStack(alignment:.leading,spacing:0) { content }
                .frame(maxWidth:.infinity,alignment:.leading)
                .background(CassiniTheme.surface,in:RoundedRectangle(cornerRadius:10))
                .overlay(RoundedRectangle(cornerRadius:10).stroke(CassiniTheme.lineSoft,lineWidth:1))
            if let caption {
                Text(UXText.text(caption))
                    .font(.system(size:11.5)).foregroundStyle(CassiniTheme.ink2)
                    .fixedSize(horizontal:false,vertical:true)
                    .padding(.top,6).padding(.horizontal,4)
            }
        }
    }
}
extension SettingsGroup where HeaderTrailing == EmptyView {
    init(_ title: String,
         subtitle: String? = nil,
         caption: String? = nil,
         @ViewBuilder content: () -> Content) {
        self.init(title, subtitle:subtitle, caption:caption, headerTrailing: { EmptyView() }, content:content)
    }
}
