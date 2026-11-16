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
        }.frame(width:700,height:560)
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
        SettingsPage {
            SettingsGroup("settings.updates.title", subtitle:"settings.updates.privacy") {
                Toggle(UXText.text("settings.updates.automatic.phase2"),isOn:$updates.automaticChecks)
                    .toggleStyle(.switch).disabled(!updates.available)
                    .accessibilityIdentifier("settings-automatic-updates")
                Divider()
                HStack {
                    VStack(alignment:.leading,spacing:4) {
                        Text(UXText.text("about.nameVersion",["version":AboutPanel.version]))
                        if updates.isUpToDate {
                            Text(UXText.text("settings.updates.upToDate")).foregroundStyle(CassiniTheme.ink2)
                        }
                    }
                    Spacer()
                    Button(UXText.text("settings.updates.checkNow")) { updates.checkForUpdates() }
                        .disabled(!updates.canCheckForUpdates).accessibilityIdentifier("settings-check-updates")
                }
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
    var body: some View {
        SettingsPage {
            SettingsGroup("settings.recording.group.starting") {
                HStack {
                    Text(UXText.text("settings.recording.shortcut.title"))
                    Spacer()
                    Text(shortcut.choice.glyph).monospaced().fontWeight(.semibold).fixedSize().accessibilityIdentifier("settings-shortcut")
                    Button(UXText.text("settings.recording.changeShortcut")) { navigation.capturingShortcut = true }.accessibilityIdentifier("settings-change-shortcut")
                }
                Divider()
                HStack {
                    SettingsDescription("settings.recording.firstRecord.title", "settings.recording.firstRecord.subtitle").accessibilityHidden(true)
                    Spacer()
                    Toggle(UXText.text("settings.recording.firstRecord.title"),isOn:Binding(get:{ !skipFirst },set:{ skipFirst = !$0 }))
                        .labelsHidden().toggleStyle(.switch).accessibilityIdentifier("settings-explain-recording")
                }
            }
            SettingsGroup("settings.recording.group.browser", subtitle:"settings.recording.group.browser.subtitle") {
                HStack(alignment:.top,spacing:18) {
                    VStack(alignment:.leading,spacing:6) {
                        Text(UXText.text("settings.recording.autoRecord.title"))
                        Text(UXText.text("settings.recording.autoRecord.subtitleShort")).font(.system(size:11.5)).foregroundStyle(CassiniTheme.ink2).fixedSize(horizontal:false,vertical:true)
                    }
                    Spacer()
                    Toggle(UXText.text("settings.recording.autoRecord.title"),isOn:Binding(get:{ CaptureCollection.shared.autoRecord },set:{ enabled in
                        Task { do { try await CaptureCollection.shared.setAutoRecord(enabled) } catch { NSApp.presentError(error) } }
                    })).labelsHidden().toggleStyle(.switch).accessibilityIdentifier("settings-auto-record")
                }
                Divider()
                Toggle(isOn:$showMenuBar) {
                    SettingsDescription("settings.general.menuBar", "settings.general.menuBar.subtitle")
                }.toggleStyle(.switch).disabled(!CaptureCollection.shared.autoRecord)
                    .accessibilityIdentifier("settings-show-menu-bar")
            }
            SettingsGroup("test.action", subtitle:"settings.recording.test.description") {
                HStack { Spacer(); Button(UXText.text("settings.recording.test.button")) { test.presented = true }
                    .disabled(!test.canStart).accessibilityIdentifier("settings-test-recording") }
            }
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
            VStack(alignment:.leading,spacing:14) {
                Text(UXText.text("settings.library.folder.title")).fontWeight(.bold)
                Text(UXText.text("settings.library.folder.descriptionShort")).foregroundStyle(CassiniTheme.ink2).lineSpacing(4)
                Text(location.displayPath).fontWeight(.semibold).textSelection(.enabled).accessibilityIdentifier("settings-library-path")
                if let stats { Text(stats).foregroundStyle(CassiniTheme.ink2).accessibilityIdentifier("settings-library-stats") }
                HStack {
                    Button(UXText.text("settings.library.show")) {
                        let root = location.roots[0]
                        Task {
                            do {
                                try await Task.detached(priority:.utility) {
                                    try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
                                }.value
                                NSWorkspace.shared.activateFileViewerSelecting([root])
                            } catch { NSApp.presentError(error) }
                        }
                    }
                    Button(UXText.text("settings.library.move")) { move.choose(parent:NSApp.keyWindow) }
                        .disabled(!move.canChoose).accessibilityIdentifier("settings-move-library")
                    if move.busy { ProgressView().controlSize(.small); Text(UXText.text("settings.library.move.moving")) }
                }
                if let problem = location.problem { Text(problem).foregroundStyle(CassiniTheme.warnInk) }
                if !move.busy, move.waitingCount > 0 {
                    Text(UXText.text("settings.library.move.waiting",["n":String(move.waitingCount)])).foregroundStyle(CassiniTheme.ink2).fixedSize(horizontal:false,vertical:true)
                }
                ForEach(move.failures) { group in
                    VStack(alignment:.leading,spacing:8) {
                        Text(UXText.text("settings.library.move.failed",["n":String(group.names.count),"folder":LibraryLocationModel.display(group.root)])).foregroundStyle(CassiniTheme.warnInk).fixedSize(horizontal:false,vertical:true)
                        Button(UXText.text("common.tryAgain")) { move.retry(root:group.root) }.disabled(move.busy).accessibilityIdentifier("settings-retry-move")
                    }
                }
            }.padding(18).frame(maxWidth:.infinity,alignment:.leading)
                .background(CassiniTheme.surface,in:RoundedRectangle(cornerRadius:8))
            SettingsGroup("settings.library.group.keepingCopy") {
                SettingsDescription("settings.library.backUp.title", "settings.library.backUp.subtitle")
                Divider()
                HStack {
                    SettingsDescription("export.zip.all", "settings.library.zip.subtitle")
                    Spacer()
                    Button(UXText.text("common.exportEllipsis")) { bulkExporter.exportAll() }
                        .disabled(!bulkExporter.canExportAll).accessibilityIdentifier("settings-export-all-zip")
                }
            }
            SettingsGroup("settings.library.group.deleted") {
                SettingsDescription("settings.library.deleted.title", "settings.library.deleted.body")
            }
        }.task(id: LibraryStore.shared.meetings.map(\.folder)) {
            let folders = LibraryStore.shared.meetings.map(\.folder)
            let bytes = await Task.detached(priority:.utility) {
                var total: Int64 = 0
                for folder in folders {
                    guard let files = FileManager.default.enumerator(at:folder,includingPropertiesForKeys:[.isRegularFileKey,.fileSizeKey,.isSymbolicLinkKey]) else { continue }
                    for case let file as URL in files {
                        guard !Task.isCancelled else { return total }
                        if let values = try? file.resourceValues(forKeys:[.isRegularFileKey,.fileSizeKey,.isSymbolicLinkKey]), values.isRegularFile == true, values.isSymbolicLink != true {
                            total += Int64(values.fileSize ?? 0)
                        }
                    }
                }
                return total
            }.value
            guard !Task.isCancelled else { return }
            stats = UXText.text("settings.library.stats",["meetings":UXText.text("library.meetingCount",["n":String(folders.count)]),"size":LibraryFormat.size(bytes:bytes)])
        }
    }
}
private struct SettingsBrowserView: View {
    var body: some View {
        SettingsPage {
            VStack(alignment:.leading,spacing:16) {
                Text(UXText.text("companion.title")).font(.headline)
                Text(UXText.text("companion.bodyShort")).foregroundStyle(CassiniTheme.ink2).lineSpacing(4)
                BrowserConnectionStateView(identifier:"settings-browser-status")
                Text(UXText.text("companion.worksWith")).foregroundStyle(CassiniTheme.ink2)
                if CompanionSetup.storeListingPublic || CaptureCollection.shared.connected {
                    Button(UXText.text("companion.addTo",["browser":CompanionSetup.shared.selectedBrowserName])) { CompanionSetup.shared.showLocalGuide(from:.settings) }
                        .buttonStyle(.link).disabled(!CompanionSetup.shared.canAdd)
                        .accessibilityIdentifier("settings-add-local-companion")
                }
            }.padding(18).background(CassiniTheme.surface,in:RoundedRectangle(cornerRadius:8))
            SettingsGroup("companion.without.heading") {
                Text(UXText.text("companion.without.body")).foregroundStyle(CassiniTheme.ink2)
            }
            Text(UXText.text("companion.privacy")).font(.caption).foregroundStyle(CassiniTheme.ink2)
        }
    }
}

private struct SettingsTranscriptionView: View {
    @State private var models = SpeechModelController.shared
    @State private var weightSize = ""
    @State private var downloadBytes: Int64 = 0
    var body: some View {
        SettingsPage {
            HStack(alignment:.top,spacing:10) {
                Image(systemName:"checkmark.shield").font(.system(size:19)).foregroundStyle(CassiniTheme.success).accessibilityHidden(true)
                Text(UXText.text("settings.transcription.privacyLine")).foregroundStyle(CassiniTheme.ink2).lineSpacing(5).fixedSize(horizontal:false,vertical:true)
            }
            VStack(alignment:.leading,spacing:10) {
                Text(UXText.text("settings.transcription.speech.heading")).fontWeight(.bold)
                Text(UXText.text("models.keepTranscript")).font(.system(size:12)).foregroundStyle(CassiniTheme.ink2).fixedSize(horizontal:false,vertical:true)
                ParakeetRecommendationView(afterFirst:false)
                ParakeetDefaultNotice()
                HStack(alignment:.top,spacing:12) {
                    SpeechRadio(selected:!models.usesParakeet,label:UXText.text("models.whistle.name")) { models.chooseParakeet(false) }
                        .frame(width:20,height:20).accessibilityIdentifier("settings-whistle-radio")
                    VStack(alignment:.leading,spacing:6) {
                        HStack(spacing:8) {
                            Text(UXText.text("models.whistle.name")).fontWeight(.semibold)
                            Text(weightSize).font(.system(size:11)).foregroundStyle(CassiniTheme.ink2)
                        }
                        Text(UXText.text("models.whistle.description.short")).font(.system(size:12)).foregroundStyle(CassiniTheme.ink2).fixedSize(horizontal:false,vertical:true)
                        if !models.usesParakeet { Text(UXText.text("models.status.inUse")).font(.system(size:11,weight:.semibold)).foregroundStyle(CassiniTheme.success) }
                    }
                    Spacer(minLength:4)
                    Text(UXText.text("models.builtIn")).font(.system(size:12)).foregroundStyle(CassiniTheme.ink2).padding(.top,2)
                }.padding(16).frame(maxWidth:.infinity,alignment:.leading)
                    .background(models.usesParakeet ? CassiniTheme.surface : CassiniTheme.activeModelWash,in:RoundedRectangle(cornerRadius:8))
                    .overlay(RoundedRectangle(cornerRadius:8).stroke(CassiniTheme.modelCardStroke))
                    .accessibilityElement(children:.contain).accessibilityIdentifier("settings-whistle-row")
                HStack(alignment:.top,spacing:12) {
                    SpeechRadio(selected:models.usesParakeet,label:UXText.text("models.parakeetUltra.name")) { models.chooseParakeet(true) }
                        .frame(width:20,height:20).disabled(!models.downloaded)
                        .accessibilityIdentifier("settings-parakeet-radio")
                    VStack(alignment:.leading,spacing:6) {
                        HStack(spacing:8) {
                            Text(UXText.text("models.parakeetUltra.name")).fontWeight(.semibold)
                            if !models.downloaded {
                                Text(UXText.text("format.size.download",["size":LibraryFormat.size(bytes:downloadBytes)]))
                                    .font(.system(size:11)).foregroundStyle(CassiniTheme.ink2)
                            }
                        }
                        Text(UXText.text("models.parakeetUltra.description.short")).font(.system(size:12)).foregroundStyle(CassiniTheme.ink2)
                        if let progress = models.progress {
                            ProgressView(value:progress).accessibilityLabel(UXText.text("models.downloading.a11y",["model":UXText.text("models.parakeetUltra.name")]))
                            Text(UXText.text("models.status.downloading",["percent":String(Int(progress * 100))])).font(.system(size:11)).foregroundStyle(CassiniTheme.ink2)
                        } else if models.downloaded {
                            Text(UXText.text(models.usesParakeet ? "models.status.inUse" : "models.status.downloaded"))
                                .font(.system(size:11,weight:.semibold)).foregroundStyle(models.usesParakeet ? CassiniTheme.success : CassiniTheme.ink2)
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
                }.padding(16).frame(maxWidth:.infinity,alignment:.leading)
                    .background(models.usesParakeet ? CassiniTheme.activeModelWash : CassiniTheme.surface,in:RoundedRectangle(cornerRadius:8))
                    .overlay(RoundedRectangle(cornerRadius:8).stroke(CassiniTheme.modelCardStroke))
                    .accessibilityElement(children:.contain).accessibilityIdentifier("settings-parakeet-row")
                if let message = models.message {
                    Text(message).font(.system(size:12)).foregroundStyle(models.failedDownload ? CassiniTheme.warnInk : CassiniTheme.ink2)
                        .fixedSize(horizontal:false,vertical:true).accessibilityIdentifier("settings-model-message")
                }
            }.accessibilityElement(children:.contain).accessibilityLabel(UXText.text("settings.transcription.speech.a11y"))
                .accessibilityIdentifier(models.recommendationReady ? "settings-speech-models-ready" : "settings-speech-models-loading")
            SettingsGroup("common.speakers", subtitle:"settings.transcription.speakers.description") {
                SavedVoiceModelRow()
                Divider()
                SavedVoicesSettingsRow()
            }
        }.task {
            let url = Bundle.main.url(forResource:"whistle",withExtension:"cact",subdirectory:"Whistle")
            let bytes = await Task.detached(priority:.utility) {
                url.flatMap { try? $0.resourceValues(forKeys:[.fileSizeKey]).fileSize }
            }.value
            if let bytes { weightSize = LibraryFormat.size(bytes:Int64(bytes)) }
            downloadBytes = await Task.detached(priority:.utility) { SpeechModelController.downloadBytes }.value
            await models.refresh()
        }
    }
}
private struct SettingsPage<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View { ScrollView { VStack(alignment:.leading,spacing:24) { content }.padding(.horizontal,28).padding(.vertical,20).frame(maxWidth:.infinity,alignment:.leading) }.background(CassiniTheme.windowGround) }
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
        VStack(alignment:.leading,spacing:4) {
            Text(UXText.text(title))
            Text(UXText.text(subtitle)).font(.system(size:11.5)).foregroundStyle(CassiniTheme.ink2)
                .fixedSize(horizontal:false,vertical:true)
        }
    }
}
struct SettingsGroup<Content: View>: View {
    let title: String
    let subtitle: String?
    @ViewBuilder let content: Content
    init(_ title: String, subtitle: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title; self.subtitle = subtitle; self.content = content()
    }
    var body: some View {
        VStack(alignment:.leading,spacing:8) {
            Text(UXText.text(title)).fontWeight(.semibold)
            if let subtitle { Text(UXText.text(subtitle)).font(.system(size:12)).foregroundStyle(CassiniTheme.ink2).fixedSize(horizontal:false,vertical:true) }
            VStack(alignment:.leading,spacing:12) { content }.padding(12).frame(maxWidth:.infinity,alignment:.leading)
                .background(CassiniTheme.surface,in:RoundedRectangle(cornerRadius:10))
        }
    }
}
