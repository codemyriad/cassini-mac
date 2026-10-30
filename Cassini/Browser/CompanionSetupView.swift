// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import Observation
import CassiniBrowserSetup

@MainActor @Observable final class CompanionSetup {
    enum Presenter { case library, settings }
    static let shared = CompanionSetup()
    var presenter: Presenter?
    @ObservationIgnored let background: BackgroundBrowserSetup
    private static var fixtureKind: String? {
        #if DEBUG
        guard MeetingRenameFixture.enabled, let kind = LibraryLaunchContext.argument("-CassiniBrowserCase"),
              ["absent","first","lost"].contains(kind) else { return nil }
        return kind
        #else
        return nil
        #endif
    }
    private init() {
        if let kind = Self.fixtureKind {
            background = BackgroundBrowserSetup {
                if kind == "absent" { throw BrowserSetupFailure.noBrowser }
                if kind == "lost" { throw BrowserSetupFailure.unwritable }
            }
            suggestedBrowser = kind == "absent" ? nil : "Chrome"
            discovered = true; hasConnected = kind == "lost"; started = true
            background.trigger()
        } else { background = BackgroundBrowserSetup { try await BrowserSetupClient().connect() } }
    }
    private(set) var started = false
    private(set) var suggestedBrowser: String?
    private(set) var discovered = false
    private(set) var hasConnected = RecordingPreferences.defaults.bool(forKey:"CassiniCompanionHasConnected")
    var noBrowser: Bool { background.state == .failed(.noBrowser) || discovered && suggestedBrowser == nil }
    var canAdd: Bool { discovered && suggestedBrowser != nil && !noBrowser }
    var showLibraryState: Bool { !noBrowser && (CaptureCollection.shared.connected || hasConnected && discovered) }
    var working: Bool { background.state == .settingUp }
    var failed: Bool { if case .failed = background.state { !noBrowser } else { false } }
    func didConnect() {
        guard !hasConnected else { return }
        hasConnected = true; RecordingPreferences.defaults.set(true,forKey:"CassiniCompanionHasConnected")
    }
    func start() {
        // AppDelegate excludes screenshot fixtures before calling this path.
        // Do not resolve Library locations/bookmarks just to start browser setup.
        guard !started else { return }
        started = true; trigger()
    }
    func trigger() {
        guard started else { return }
        background.trigger()
        guard Self.fixtureKind == nil else { return }
        Task {
            let name = await Task.detached(priority:.utility) { () -> String? in
                BrowserSetupInstallation.installedBrowsers().first?.name
            }.value
            suggestedBrowser = name; discovered = true
        }
    }
    func connect() { trigger() }
    func close() { presenter = nil }
    func stop() { background.stop() }
    var stateLine: String {
        if noBrowser { return UXText.text("browser.state.needsBrowser") }
        let names = Set(CaptureCollection.shared.peers.filter(\.reconciled).compactMap(\.browser))
        if CaptureCollection.shared.connected {
            return names.count == 1 ? UXText.text("browser.state.connected",["browser":names.first!]) : UXText.text("browser.state.connectedGeneric")
        }
        switch background.state {
        case .settingUp: return UXText.text("browser.state.settingUp")
        case .waiting: return UXText.text("browser.state.waiting")
        case .failed(let failure):
            let key: String = switch failure {
            case .noBrowser: "browser.state.reason.noBrowser"
            case .unwritable: "browser.state.reason.unwritable"
            case .unsafe: "browser.state.reason.unsafe"
            case .temporary: "browser.state.reason.temporary"
            }
            return UXText.text("browser.state.failed",["reason":UXText.text(key)])
        }
    }
    var addLabel: String {
        suggestedBrowser.map { UXText.text("browser.state.add",["browser":$0]) } ?? UXText.text("browser.state.addGeneric")
    }
    func add() {
        guard !LibraryLaunchContext.current.screenshot, Self.fixtureKind == nil, canAdd else { return }
        let url = URL(string:"https://chromewebstore.google.com/detail/pcafdaahfhjiolfpfnlhmljfgoabbaij")!
        let identifiers = BrowserSetupInstallation.supportedBrowsers.map(\.bundleID)
        let preferred = NSWorkspace.shared.urlForApplication(toOpen:url)
        let apps = identifiers.compactMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier:$0) }
        if let app = preferred.flatMap({ apps.contains($0) ? $0 : nil }) ?? apps.first {
            NSWorkspace.shared.open([url],withApplicationAt:app,configuration:NSWorkspace.OpenConfiguration())
        }
    }
}
struct CompanionSetupView: View {
    @State private var setup = CompanionSetup.shared
    @State private var captures = CaptureCollection.shared
    private var sample: Bool {
        #if DEBUG
        LibraryLaunchContext.current.screenshot && LibraryLaunchContext.argument("-CassiniCompanionBoard") == "YES"
        #else
        false
        #endif
    }
    private var connected: Bool { !sample && captures.connected }
    private var browsers: [String] { sample ? ["Chrome"] : Array(Set(captures.peers.filter(\.reconciled).compactMap(\.browser))).sorted() }
    private var added: Bool { sample || connected }
    var body: some View {
        VStack(alignment:.leading,spacing:20) {
            VStack(alignment:.leading,spacing:6) {
                Text(UXText.text("companion.title")).font(.system(size:20,weight:.bold)).accessibilityAddTraits(.isHeader)
                Text(UXText.text("companion.body")).foregroundStyle(LibraryTheme.dim).lineSpacing(4).fixedSize(horizontal:false,vertical:true)
            }
            VStack(spacing:0) {
                step(1,done:added,title:"companion.addStep.title",caption:addCaption) {
                    if !added { Button(UXText.text("companion.add")) { setup.add() }.buttonStyle(.borderedProminent).disabled(!setup.canAdd).accessibilityIdentifier("companion-add") }
                }
                Divider()
                step(2,done:connected,title:"companion.connectStep.title",caption:connectCaption) {
                    if added && !connected && setup.failed {
                        Button(UXText.text("common.tryAgain")) { setup.connect() }
                            .buttonStyle(.borderedProminent).disabled(setup.working).accessibilityIdentifier("companion-connect")
                    }
                }
            }.background(Color(nsColor:.textBackgroundColor),in:RoundedRectangle(cornerRadius:8))
                .overlay { RoundedRectangle(cornerRadius:8).stroke(Color.secondary.opacity(0.25)) }
            HStack(alignment:.top,spacing:10) {
                Image(systemName:"lock").frame(width:14).accessibilityHidden(true)
                Text(UXText.text("companion.privacy")).fixedSize(horizontal:false,vertical:true)
            }.font(.system(size:11.5)).foregroundStyle(LibraryTheme.dim)
            HStack(spacing:10) {
                Spacer()
                Button(UXText.text("common.notNow")) { setup.close() }.keyboardShortcut(.cancelAction)
                Button(UXText.text("common.done")) { setup.close() }.keyboardShortcut(.defaultAction).disabled(!connected)
            }.controlSize(.large)
        }.font(.system(size:13)).padding(26).frame(width:540)
            .accessibilityElement(children:.contain).accessibilityLabel(UXText.text("companion.title"))
            .accessibilityIdentifier("companion-setup-dialog")
    }
    private var addCaption: String {
        if !sample && setup.noBrowser { return UXText.text("browser.state.needsBrowser") }
        if !added { return UXText.text("companion.addStep.notAdded") }
        if browsers.count == 1 { return UXText.text("companion.addStep.done",["browser":browsers[0]]) }
        if browsers.isEmpty { return UXText.text("settings.browser.status.connectedGeneric") }
        let formatter = ListFormatter(); formatter.locale = Locale(identifier:"en_GB")
        return UXText.text("companion.addStep.doneSeveral",["browsers":formatter.string(from:browsers) ?? browsers.joined(separator:", ")])
    }
    private var connectCaption: String { added ? setup.stateLine : "" }
    private func step<Content:View>(_ number: Int, done: Bool, title: String, caption: String, @ViewBuilder action: () -> Content) -> some View {
        HStack(spacing:14) {
            ZStack {
                if done { Circle().fill(Color(red:31/255,green:122/255,blue:63/255)); Image(systemName:"checkmark").fontWeight(.bold).foregroundStyle(.white) }
                else {
                    Circle().stroke(Color.accentColor,lineWidth:2)
                    if number == 2 && added && setup.working { ProgressView().controlSize(.small) }
                    else { Text(String(number)).fontWeight(.bold).foregroundStyle(Color.accentColor) }
                }
            }.frame(width:28,height:28)
                .accessibilityElement(children:.ignore).accessibilityLabel(UXText.text(done ? "companion.step.a11y.done" : number == 2 && added && setup.working ? "companion.step.a11y.working" : "companion.step.a11y.pending",["n":String(number)]))
            VStack(alignment:.leading,spacing:3) {
                Text(UXText.text(title)).fontWeight(.semibold)
                if !caption.isEmpty { Text(caption).font(.system(size:11.5)).foregroundStyle(number == 2 && setup.failed && !done ? LibraryTheme.amber : LibraryTheme.dim).fixedSize(horizontal:false,vertical:true) }
            }
            Spacer(minLength:4)
            action().controlSize(.large)
        }.padding(.horizontal,16).padding(.vertical,14).frame(minHeight:62)
    }
}
