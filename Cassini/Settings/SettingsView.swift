// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import AppKit
import Observation
import CassiniLibrary

enum SettingsTab: String, CaseIterable { case recording, transcription, library, browser
    var title: String {
        UXText.text(self == .recording ? "settings.tab.recording" : self == .transcription ? "settings.tab.transcription" : self == .library ? "settings.tab.library" : "settings.tab.browserCompanion")
    }
    var icon: String { self == .recording ? "mic" : self == .transcription ? "text.alignleft" : self == .library ? "folder" : "macwindow" }
}
@MainActor @Observable final class SettingsNavigation {
    static let shared = SettingsNavigation()
    var tab = SettingsTab.recording
    var capturingShortcut = false
    @ObservationIgnored var open: (() -> Void)?
}
struct CassiniSettingsView: View {
    @State private var navigation = SettingsNavigation.shared
    var body: some View {
        TabView(selection:$navigation.tab) {
            SettingsRecordingView().tabItem { Label(SettingsTab.recording.title,systemImage:SettingsTab.recording.icon) }.tag(SettingsTab.recording)
            SettingsTranscriptionView().tabItem { Label(SettingsTab.transcription.title,systemImage:SettingsTab.transcription.icon) }.tag(SettingsTab.transcription)
            SettingsLibraryView().tabItem { Label(SettingsTab.library.title,systemImage:SettingsTab.library.icon) }.tag(SettingsTab.library)
            SettingsBrowserView().tabItem { Label(SettingsTab.browser.title,systemImage:SettingsTab.browser.icon) }.tag(SettingsTab.browser)
        }.frame(width:700,height:500)
            .preferredColorScheme(LibraryLaunchContext.current.screenshot ? .light : nil)
            .font(.system(size:13)).accessibilityLabel(UXText.text("settings.pages.a11y"))
            .background(WindowAccessor { window in
                guard let window else { return }
                window.title = UXText.text("settings.title"); window.setAccessibilityIdentifier("cassini-settings-window")
                #if DEBUG
                SettingsFixture.prepare(window)
                #endif
            })
    }
}
private struct SettingsRecordingView: View {
    @AppStorage("CassiniSkipRecordFirst",store:RecordingPreferences.defaults) private var skipFirst = false
    @State private var shortcut = RecordingRuntime.shared.shortcut
    @State private var navigation = SettingsNavigation.shared
    var body: some View {
        SettingsPage {
            VStack(alignment:.leading,spacing:18) {
                HStack {
                    Text(UXText.text("settings.recording.shortcut.title"))
                    Spacer()
                    Text(shortcut.choice.glyph).monospaced().fontWeight(.semibold).fixedSize().accessibilityIdentifier("settings-shortcut")
                    Button(UXText.text("settings.recording.changeShortcut")) { navigation.capturingShortcut = true }.accessibilityIdentifier("settings-change-shortcut")
                }
                Divider()
                HStack {
                    Text(UXText.text("settings.recording.firstRecord.title")).accessibilityHidden(true)
                    Spacer()
                    Toggle(UXText.text("settings.recording.firstRecord.title"),isOn:Binding(get:{ !skipFirst },set:{ skipFirst = !$0 }))
                        .labelsHidden().toggleStyle(.switch).accessibilityIdentifier("settings-explain-recording")
                }
            }.padding(18).background(Color(nsColor:.textBackgroundColor),in:RoundedRectangle(cornerRadius:8))
        }.sheet(isPresented:$navigation.capturingShortcut) {
            VStack(alignment:.leading,spacing:18) {
                Text(UXText.text("settings.recording.shortcut.title")).font(.system(size:17,weight:.bold))
                ShortcutCaptureView { candidate in
                    let code = shortcut.change(to:candidate)
                    if code == noErr { navigation.capturingShortcut = false }
                    else { NSApp.presentError(NSError(domain:NSOSStatusErrorDomain,code:Int(code))) }
                } cancel:{ navigation.capturingShortcut = false }
                    .frame(height:60).background(LibraryTheme.chip,in:RoundedRectangle(cornerRadius:8))
                    .overlay { Text(shortcut.choice.glyph).font(.system(size:20,design:.monospaced)).foregroundStyle(LibraryTheme.dim).allowsHitTesting(false) }
                    .accessibilityLabel(UXText.text("settings.recording.shortcut.title"))
                HStack { Spacer(); Button(UXText.text("common.cancel")) { navigation.capturingShortcut = false }.keyboardShortcut(.cancelAction) }
            }.padding(26).frame(width:440)
        }
    }
}
private struct SettingsLibraryView: View {
    @State private var location = LibraryLocationModel.shared
    @State private var move = LibraryMoveCoordinator.shared
    @State private var recorder = RecordingController.shared
    var body: some View {
        SettingsPage {
            VStack(alignment:.leading,spacing:14) {
                Text(UXText.text("settings.library.folder.title")).fontWeight(.bold)
                Text(UXText.text("settings.library.folder.description")).foregroundStyle(LibraryTheme.dim).lineSpacing(4)
                Text(location.displayPath).fontWeight(.semibold).textSelection(.enabled).accessibilityIdentifier("settings-library-path")
                HStack {
                    Button(UXText.text("settings.library.show")) {
                        let root = location.roots[0]
                        do { guard location.available else { throw POSIXError(.ENOENT) }; try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700]); NSWorkspace.shared.activateFileViewerSelecting([root]) }
                        catch { NSApp.presentError(error) }
                    }
                    Button(UXText.text("settings.library.move")) { move.choose(parent:NSApp.keyWindow) }
                        .disabled(move.busy || recorder.isStarting || recorder.isSaving).accessibilityIdentifier("settings-move-library")
                    if move.busy { ProgressView().controlSize(.small); Text(UXText.text("settings.library.move.moving")) }
                }
                if let problem = location.problem { Text(problem).foregroundStyle(LibraryTheme.amber) }
                if !move.busy, move.waitingCount > 0 {
                    Text(UXText.text("settings.library.move.waiting",["n":String(move.waitingCount)])).foregroundStyle(LibraryTheme.dim).fixedSize(horizontal:false,vertical:true)
                }
                ForEach(move.failures) { group in
                    VStack(alignment:.leading,spacing:8) {
                        Text(UXText.text("settings.library.move.failed",["n":String(group.names.count),"folder":LibraryLocationModel.display(group.root)])).foregroundStyle(LibraryTheme.amber).fixedSize(horizontal:false,vertical:true)
                        Button(UXText.text("common.tryAgain")) { move.retry(root:group.root) }.disabled(move.busy).accessibilityIdentifier("settings-retry-move")
                    }
                }
            }.padding(18).frame(maxWidth:.infinity,alignment:.leading)
                .background(Color(nsColor:.textBackgroundColor),in:RoundedRectangle(cornerRadius:8))
        }
    }
}
private struct SettingsBrowserView: View {
    @State private var companion = BrowserCompanionSnapshot()
    private var status: String {
        guard companion.connected else { return UXText.text("settings.browser.status.notSetUp") }
        return companion.browser.map { UXText.text("settings.browser.status.connected",["browser":$0]) } ?? UXText.text("settings.browser.status.connectedGeneric")
    }
    var body: some View {
        SettingsPage {
            VStack(alignment:.leading,spacing:16) {
                Text(UXText.text("settings.browser.description")).foregroundStyle(LibraryTheme.dim).lineSpacing(4)
                HStack {
                    Text(status).accessibilityIdentifier("settings-browser-status")
                    Spacer()
                    Button(UXText.text("meeting.companionCard.setUp")) {
                        NSWorkspace.shared.open(URL(string:"https://github.com/codemyriad/cassini-mac#record-meetings-in-your-browser")!)
                    }
                }
            }.padding(18).background(Color(nsColor:.textBackgroundColor),in:RoundedRectangle(cornerRadius:8))
        }.task {
            while !Task.isCancelled {
                let directory = LibraryLaunchContext.locationFile.deletingLastPathComponent().appendingPathComponent(".cassini-browser-connections")
                companion = await Task.detached(priority:.utility) { BrowserCompanionConnection.snapshot(directory:directory) }.value
                do { try await Task.sleep(for:.seconds(2)) } catch { return }
            }
        }
    }
}
private struct SettingsTranscriptionView: View {
    private var weightSize: String {
        let url = Bundle.main.url(forResource:"whistle",withExtension:"cact",subdirectory:"Whistle")
        let count = url.flatMap { try? $0.resourceValues(forKeys:[.fileSizeKey]).fileSize } ?? 16_919_407
        return LibraryFormat.size(bytes:Int64(count))
    }
    var body: some View {
        SettingsPage {
            HStack(alignment:.top,spacing:10) {
                Image(systemName:"checkmark.shield").font(.system(size:19)).foregroundStyle(.green).accessibilityHidden(true)
                Text(UXText.text("settings.transcription.privacy")).foregroundStyle(LibraryTheme.dim).lineSpacing(5).fixedSize(horizontal:false,vertical:true)
            }
            VStack(alignment:.leading,spacing:10) {
                Text(UXText.text("settings.transcription.speech.heading")).fontWeight(.bold)
                Text(UXText.text("settings.transcription.speech.description")).font(.system(size:12)).foregroundStyle(LibraryTheme.dim).fixedSize(horizontal:false,vertical:true)
                HStack(alignment:.top,spacing:12) {
                    Image(systemName:"largecircle.fill.circle").foregroundStyle(Color.accentColor).font(.system(size:17)).padding(.top,2).accessibilityHidden(true)
                    VStack(alignment:.leading,spacing:6) {
                        HStack(spacing:8) {
                            Text(UXText.text("models.whistle.name")).fontWeight(.semibold)
                            Text(weightSize).font(.system(size:11)).foregroundStyle(LibraryTheme.dim)
                        }
                        Text(UXText.text("models.whistle.description")).font(.system(size:12)).foregroundStyle(LibraryTheme.dim).fixedSize(horizontal:false,vertical:true)
                        Text(UXText.text("models.status.inUse")).font(.system(size:11,weight:.semibold)).foregroundStyle(.green)
                    }
                    Spacer(minLength:4)
                    Text(UXText.text("models.included")).font(.system(size:12)).foregroundStyle(LibraryTheme.dim).padding(.top,2)
                }.padding(16).frame(maxWidth:.infinity,alignment:.leading)
                    .background(Color.accentColor.opacity(0.07),in:RoundedRectangle(cornerRadius:8))
                    .overlay(RoundedRectangle(cornerRadius:8).stroke(LibraryTheme.dim.opacity(0.2)))
                    .accessibilityElement(children:.combine).accessibilityIdentifier("settings-whistle-row")
            }.accessibilityElement(children:.contain).accessibilityLabel(UXText.text("settings.transcription.speech.a11y"))
            VStack(alignment:.leading,spacing:12) {
                Text(UXText.text("settings.transcription.network.heading")).fontWeight(.bold)
                HStack(alignment:.top,spacing:10) {
                    Text("•").accessibilityHidden(true)
                    Text(UXText.text("settings.transcription.network.download")).foregroundStyle(LibraryTheme.dim).lineSpacing(4).fixedSize(horizontal:false,vertical:true)
                }
            }
        }
    }
}
private struct SettingsPage<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View { ScrollView { VStack(alignment:.leading,spacing:24) { content }.padding(32).frame(maxWidth:.infinity,alignment:.leading) }.background(Color(nsColor:.windowBackgroundColor)) }
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
