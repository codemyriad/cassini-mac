// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import Observation
import CassiniLibrary
import CassiniRecording

@MainActor enum RecordingPreferences {
    static var defaults: UserDefaults {
        #if DEBUG
        if let defaults = SettingsFixture.defaults { return defaults }
        if RecordingFixture.enabled, let id = LibraryLaunchContext.argument("-CassiniCaptureID") {
            return UserDefaults(suiteName: "io.codemyriad.cassini.capture-fixture." + id)!
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
        if RecordingOverview.active || RecordingOverview.starting { _ = stopFromShortcut(notify:!NSApp.isActive); return }
        guard RecordingOverview.canStart else { return }
        let introduction = !RecordingPreferences.skipFirst
        if introduction { MeetingNavigation.shared.openLibrary?(); NSApp.activate(ignoringOtherApps: true) }
        request(parent: LibraryLocationModel.shared.roots[0], showRecording: introduction)
    }
    @discardableResult func stopFromShortcut(notify: Bool) -> Task<Void,Never> {
        let native = RecordingController.shared
        let folder = native.isRecording ? native.directory : nil, title = native.title
        let owned = Array(CaptureCollection.shared.captures.values)
        RecordingOverview.stop()
        return Task {
            await RecordingPageModel.flushAll()
            await RecordingOverview.stopAndWait()
            guard notify else { return }
            if let folder, native.lastCompletedDirectory == folder, native.problem == nil {
                CaptureNotifications.shared.saved(folder:folder,title:title)
            }
            for value in owned where value.owner.snapshot.phase == .saved {
                let snapshot = value.owner.snapshot
                guard snapshot.manifest.state == "completed", snapshot.manifest.tracks.contains(where:{ $0.frames > 0 }) else { continue }
                CaptureNotifications.shared.saved(folder:snapshot.directory,title:value.displayTitle ?? snapshot.manifest.title)
            }
        }
    }
    func openCurrent() {
        guard let folder = RecordingOverview.directory else { return }
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
            await CaptureNotifications.shared.authorize()
            do { try await CaptureCollection.shared.record() } catch { /* Catalog failure banner owns presentation. */ }
        }
    }
}

struct RecordFirstView: View {
    @AppStorage("CassiniSkipRecordFirst",store:RecordingPreferences.defaults) private var skip = false
    @State private var microphoneAllowed = false
    @State private var systemPreviouslyCaptured = false
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
                source(icon: "mic.fill", title: "common.yourMicrophone", description: "recordFirst.mic.description", caption: microphoneAllowed ? "recordFirst.allowed" : "recordFirst.mic.caption")
                Divider()
                if CaptureCollection.shared.hasCalls {
                    source(icon:"macwindow",title:"common.theOthers",description:"whatIsRecorded.othersHeard.browserMixed.description",caption:nil)
                } else {
                    source(icon:"display",title:"recordFirst.sound.title",description:"recordFirst.sound.description",caption:systemPreviouslyCaptured ? "recordFirst.allowed" : "recordFirst.sound.caption")
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
            .onAppear(perform:refreshPermission)
            .onReceive(NotificationCenter.default.publisher(for:NSApplication.didBecomeActiveNotification)) { _ in refreshPermission() }
    }
    private func refreshPermission() {
        systemPreviouslyCaptured = SystemAudioCaptureKnowledge.shared.previouslyCaptured
        #if DEBUG
        if RecordingFixture.enabled, LibraryLaunchContext.argument("-CassiniConsentAllowed") == "YES" { microphoneAllowed = true; return }
        #endif
        microphoneAllowed = CaptureSettings.microphoneAllowed
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
    @State private var elapsedMs: Int64 = 0
    @State private var previewSpectrogram: RecordingSpectrogram?
    @Environment(\.colorScheme) private var colorScheme
    private var displayedMs: Int64 { frozenMs ?? elapsedMs }
    var body: some View {
        RecordingPillControls(time:LibraryFormat.liveBadge(displayedMs),
            label:UXText.text("recording.pill.open.a11y",["time":LibraryFormat.liveBig(displayedMs)]),
            microphone:microphone,output:output,silent:frozenMs != nil || RecordingOverview.microphoneSilent,
            controller:frozenMs == nil ? RecordingOverview.spectrogram : previewSpectrogram,
            noSleep:RecordingRuntime.shared.power.held,dark:colorScheme == .dark,
            open:{ if frozenMs == nil { RecordCoordinator.shared.openCurrent() } },
            stop:{ if frozenMs == nil { RecordingOverview.stop() } })
            .fixedSize().frame(height:34)
            .task {
                if let frozenMs {
                    #if DEBUG
                    previewSpectrogram = RecordingSpectrogram.frozenPreview(atMs:frozenMs)
                    #endif
                    return
                }
                while !Task.isCancelled {
                    elapsedMs = RecordingOverview.elapsedMs
                    do { try await Task.sleep(for:.seconds(1)) } catch { return }
                }
            }
    }
}

/// A native accessibility group keeps the toolbar's first-action description
/// from replacing the labels of its other controls (including Stop).
private struct RecordingPillControls: NSViewRepresentable {
    let time: String, label: String
    let microphone: Float, output: Float
    let silent: Bool
    let controller: RecordingSpectrogram?
    let noSleep: Bool, dark: Bool
    let open: () -> Void, stop: () -> Void
    func makeNSView(context: Context) -> RecordingPillControlView { RecordingPillControlView() }
    func updateNSView(_ view: RecordingPillControlView, context: Context) {
        view.update(self)
    }
}
private final class RecordingPillControlView: NSView {
    private let openButton = RecordingPillAction(), stopButton = RecordingPillAction()
    private let me = RecordingPillMeter(), others = RecordingPillMeter()
    private let spectrogram = RecordingSpectrogramView(style:.pill)
    private var openWidth: NSLayoutConstraint!, stopWidth: NSLayoutConstraint!
    private var onOpen: (() -> Void)?, onStop: (() -> Void)?
    override init(frame: NSRect) {
        super.init(frame:frame)
        wantsLayer = true; layer?.cornerRadius = 6
        setAccessibilityElement(true); setAccessibilityRole(.group)
        for button in [openButton,stopButton] {
            button.isBordered = false; button.setButtonType(.momentaryPushIn)
            button.target = self; button.font = .systemFont(ofSize:13,weight:.semibold)
            button.heightAnchor.constraint(equalToConstant:26).isActive = true
        }
        openButton.action = #selector(openRecording); stopButton.action = #selector(stopRecording)
        openButton.setAccessibilityIdentifier("recording-open-current")
        stopButton.setAccessibilityIdentifier("recording-stop")
        openButton.toolTip = UXText.text("hidden.openCassini")
        openWidth = openButton.widthAnchor.constraint(equalToConstant:84); openWidth.isActive = true
        stopWidth = stopButton.widthAnchor.constraint(equalToConstant:44); stopWidth.isActive = true
        stopButton.wantsLayer = true; stopButton.layer?.cornerRadius = 5
        let meters = NSView()
        meters.widthAnchor.constraint(equalToConstant:50).isActive = true
        meters.heightAnchor.constraint(equalToConstant:20).isActive = true
        spectrogram.frame = .init(x:0,y:0,width:50,height:20); meters.addSubview(spectrogram)
        me.frame = .init(x:0,y:11,width:50,height:9); others.frame = .init(x:0,y:0,width:50,height:9)
        for meter in [me,others] { meters.addSubview(meter) }
        me.setAccessibilityLabel(UXText.text("common.yourMicrophone"))
        others.setAccessibilityLabel(UXText.text("common.theOthers"))
        let row = NSStackView(views:[openButton,meters,stopButton]); row.spacing = 8; row.alignment = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false; addSubview(row)
        NSLayoutConstraint.activate([row.leadingAnchor.constraint(equalTo:leadingAnchor,constant:10),row.trailingAnchor.constraint(equalTo:trailingAnchor,constant:-4),row.centerYAnchor.constraint(equalTo:centerYAnchor)])
        setAccessibilityChildren([openButton,me,others,stopButton])
    }
    required init?(coder: NSCoder) { nil }
    override var intrinsicContentSize: NSSize { NSSize(width:openWidth.constant + stopWidth.constant + 50 + 16 + 14,height:34) }
    func update(_ value: RecordingPillControls) {
        onOpen = value.open; onStop = value.stop
        let red: NSColor = value.dark ? NSColor(red:1,green:69/255,blue:58/255,alpha:1) : NSColor(red:215/255,green:0,blue:21/255,alpha:1)
        let font = NSFont.monospacedDigitSystemFont(ofSize:13,weight:.semibold)
        openButton.attributedTitle = NSAttributedString(string:value.time,attributes:[.font:font,.foregroundColor:red])
        openButton.image = NSImage(size:NSSize(width:17,height:10),flipped:false) { _ in
            red.setFill(); NSBezierPath(ovalIn:NSRect(x:0,y:0.5,width:9,height:9)).fill(); return true
        }
        openButton.imagePosition = .imageLeft; openButton.imageHugsTitle = true
        openButton.spokenLabel = value.label
        let stopTitle = UXText.text("common.stop"), stopFont = NSFont.systemFont(ofSize:11,weight:.semibold)
        stopButton.attributedTitle = NSAttributedString(string:stopTitle,attributes:[.font:stopFont,.foregroundColor:NSColor.white])
        stopButton.spokenLabel = UXText.text("recording.pill.stop.a11y")
        stopButton.layer?.backgroundColor = red.cgColor
        layer?.backgroundColor = (value.dark
            ? NSColor(srgbRed:67/255,green:33/255,blue:31/255,alpha:1)
            : NSColor(srgbRed:253/255,green:228/255,blue:230/255,alpha:1)).cgColor
        openWidth.constant = ceil((value.time as NSString).size(withAttributes:[.font:font]).width) + 21
        stopWidth.constant = ceil((stopTitle as NSString).size(withAttributes:[.font:stopFont]).width) + 20
        toolTip = value.noSleep ? UXText.text("recording.pill.noSleep") : nil
        spectrogram.configure(value.controller,dark:value.dark,silent:value.silent)
        me.update(value.microphone,color:red,silent:value.silent)
        others.update(value.output,color:red,silent:false)
        invalidateIntrinsicContentSize()
    }
    @objc private func openRecording() { onOpen?() }
    @objc private func stopRecording() { onStop?() }
}
private final class RecordingPillAction: NSButton {
    var spokenLabel = ""
    override func accessibilityLabel() -> String? { spokenLabel }
}
private final class RecordingPillMeter: NSView {
    private let fill = CALayer()
    override init(frame: NSRect) {
        super.init(frame:frame); wantsLayer = true; layer?.cornerRadius = 2
        fill.cornerRadius = 2; layer?.addSublayer(fill)
        setAccessibilityElement(true); setAccessibilityRole(.progressIndicator)
    }
    required init?(coder: NSCoder) { nil }
    private var value: CGFloat = 0
    func update(_ level: Float, color: NSColor, silent: Bool) {
        value = CGFloat(max(0,min(1,level)))
        layer?.backgroundColor = NSColor.clear.cgColor
        fill.isHidden = true
        setAccessibilityValue(NSNumber(value:Double(value)))
        needsLayout = true
    }
    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        fill.frame = NSRect(x:0,y:0,width:bounds.width * value,height:bounds.height)
        CATransaction.commit()
    }
}
