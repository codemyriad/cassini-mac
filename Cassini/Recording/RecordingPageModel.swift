// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import CassiniLibrary
import CassiniRecording
import CassiniWhistle
import Observation

private actor RecordingEdits {
    let directory: URL
    let id: UUID
    private var titleToken = 0
    init(directory: URL, id: UUID) { self.directory = directory; self.id = id }
    func title(_ title: String, token: Int) throws {
        guard token > titleToken else { return }; titleToken = token
        try MeetingMetadataWriter(directory: directory, id: id).transaction { metadata in
            metadata["title"] = title.isEmpty ? NSNull() : title as Any
            metadata["titleSource"] = title.isEmpty ? "meeting-window" : "user"
        }
    }
}
@MainActor @Observable final class RecordingPageModel {
    private static var editors: [String:RecordingPageModel] = [:]
    static func editor(for meeting: LibraryMeeting) -> RecordingPageModel {
        // View initializers look this up during rendering; lookup must not
        // publish observed changes back into the same render pass.
        if let model = editors[meeting.folder.path] { return model }
        // Keep the current editor across Back/Open, even before the watcher has
        // observed its last write. Retain older editors only while writes settle.
        editors = editors.filter { $0.value.titleTask != nil }
        let model = RecordingPageModel(meeting)
        editors[meeting.folder.path] = model; return model
    }
    static func discard(for folder: URL) async {
        guard let model = editors.removeValue(forKey:folder.path) else { return }
        model.discarded = true
        model.titleDirty = false
        model.titleTask?.cancel(); model.voiceTask?.cancel()
        await model.titleTask?.value
    }
    static var hasPendingEdits: Bool { editors.values.contains { $0.titleTask != nil } }
    static func flushAll() async {
        let models = Array(editors.values)
        for model in models { model.flush() }
        for model in models { await model.titleTask?.value }
    }
    private(set) var meeting: LibraryMeeting
    var title: String
    private var cachedVoiceCount: Int = 0
    var voiceCount: Int {
        if let owned { return owned.snapshot.manifest.tracks.filter { ["remote","media","tab"].contains($0.kind) && $0.ended != true }.count }
        return cachedVoiceCount
    }
    private var discarded = false
    private(set) var frozen = false
    @ObservationIgnored private let edits: RecordingEdits
    @ObservationIgnored private var titleTask: Task<Void,Never>?
    @ObservationIgnored private var titleGeneration = 0
    @ObservationIgnored private var titleDirty = false
    @ObservationIgnored private var voiceTask: Task<Void,Never>?
    @ObservationIgnored private var sourceGeneration = 0
    @ObservationIgnored private var liveAnchor = ProcessInfo.processInfo.systemUptime
    @ObservationIgnored private var liveElapsed: Int64 = 0
    private init(_ meeting: LibraryMeeting) {
        self.meeting = meeting; title = meeting.title ?? UXText.text("library.untitled")
        edits = RecordingEdits(directory: meeting.folder, id: meeting.id)
        liveElapsed = meeting.state.liveMs ?? meeting.durationMs ?? 0
        #if DEBUG
        frozen = LibraryLaunchContext.current.screenshot
        #endif
        if frozen { cachedVoiceCount = 4 } // Published Recording board's frozen source-count state.
        else { refreshVoices() }
    }
    func update(_ meeting: LibraryMeeting) {
        // A cached editor may have been hidden since recording stopped. Only
        // extrapolate while the incoming snapshot is still recording; Saving
        // uses the producer's recorded end, not time spent away from the view.
        let elapsed = meeting.state.lifecycle == .recording ? elapsedMs : (meeting.state.liveMs ?? meeting.durationMs ?? liveElapsed)
        self.meeting = meeting
        liveElapsed = meeting.state.lifecycle == .recording ? max(elapsed,meeting.state.liveMs ?? 0) : elapsed
        liveAnchor = ProcessInfo.processInfo.systemUptime
        if !frozen { refreshVoices() }
    }
    private func refreshVoices() {
        guard meeting.isBrowserCapture else { cachedVoiceCount = 0; return }
        guard owned == nil else { return }
        voiceTask?.cancel(); sourceGeneration += 1
        let revision = sourceGeneration, folder = meeting.folder
        voiceTask = Task { [weak self] in
            let count = await Task.detached {
                guard let data = try? WhistleIO.readRegular(folder.appendingPathComponent("session.json"),maximum:1_048_576),
                      let manifest = try? RecordingLoader.decode(data) else { return 0 }
                return manifest.tracks.filter { ["remote","media","tab"].contains($0.kind) && $0.ended != true }.count
            }.value
            guard let self, !Task.isCancelled, revision == self.sourceGeneration else { return }
            self.cachedVoiceCount = count; self.voiceTask = nil
        }
    }
    var native: Bool {
        RecordingController.shared.directory?.standardizedFileURL.path == meeting.folder.standardizedFileURL.path
    }
    var owned: LiveCapture? {
        guard let capture = CaptureCollection.shared.captures[meeting.id], capture.snapshot.directory.standardizedFileURL.path == meeting.folder.standardizedFileURL.path else { return nil }
        return capture
    }
    var canStop: Bool { native || owned != nil }
    var saving: Bool { owned.map { $0.savingSinceMs != nil || $0.snapshot.phase == .saving } ?? (native && RecordingController.shared.isSaving) }
    var me: Bool { owned?.snapshot.me ?? true }
    var others: Bool { owned?.snapshot.others ?? true }
    var othersUnavailable: Bool { owned?.input.failedSides.contains(.others) == true }
    var othersPathTitle: String {
        let browser = owned?.snapshot.browserAlive ?? meeting.isBrowserCapture
        return UXText.text(!others || othersUnavailable ? "whatIsRecorded.othersHeard.none.title" : browser ? "common.listeningInsideBrowser" : "whatIsRecorded.othersHeard.system.title")
    }
    var othersPathBody: String {
        let key: String
        if !others { key = "whatIsRecorded.othersHeard.none.description" }
        else if othersUnavailable { key = "errors.othersPermission.line" }
        else if owned?.snapshot.browserAlive ?? meeting.isBrowserCapture { key = voiceCount > 1 ? "whatIsRecorded.othersHeard.browser.description" : "whatIsRecorded.othersHeard.browserMixed.description" }
        else { key = owned?.snapshot.fallbackReason == nil ? "whatIsRecorded.othersHeard.system.description" : "whatIsRecorded.othersHeard.fallback.description" }
        return UXText.text(key)
    }
    func stop() { if owned != nil { CaptureCollection.shared.stop(meeting.id) } else if native { RecordingController.shared.stop() } }
    var elapsedMs: Int64 {
        if let owned { return owned.elapsedMs }
        if native { return RecordingController.shared.elapsedMs }
        if frozen || meeting.state.lifecycle != .recording { return meeting.state.liveMs ?? liveElapsed }
        return liveElapsed + Int64(max(0,ProcessInfo.processInfo.systemUptime - liveAnchor) * 1000)
    }
    var microphone: Float { owned?.levels[.me] ?? (native ? RecordingController.shared.levels["microphone",default:0] : 0) }
    var output: Float { owned?.levels[.others] ?? (native ? RecordingController.shared.levels["output",default:0] : (frozen ? 0.58 : 0)) }
    var microphoneSilent: Bool {
        if let owned { return owned.microphoneSilent }
        return native ? RecordingController.shared.microphoneSilent : frozen
    }
    var displayTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? UXText.text("library.untitled") : title }
    func changeTitle() {
        title = String(String.UnicodeScalarView(title.unicodeScalars.prefix(500)))
        guard !frozen, !discarded else { return }
        // Publish the current user input immediately; persistence is debounced.
        // Older writes cannot replace this value after a later binding update.
        if native { RecordingController.shared.title = displayTitle }
        if owned != nil { CaptureCollection.shared.title(meeting.id,displayTitle) }
        titleDirty = true; scheduleTitle()
    }
    func flush() { guard !discarded else { return }; if titleDirty { scheduleTitle(immediate:true) } }
    private func scheduleTitle(immediate: Bool = false) {
        titleTask?.cancel(); titleGeneration += 1
        let generation = titleGeneration, value = title.trimmingCharacters(in:.whitespacesAndNewlines)
        titleTask = Task {
            defer { if titleGeneration == generation { titleTask = nil } }
            do {
                if !immediate { try await Task.sleep(for:.milliseconds(400)) }
                try Task.checkCancellation(); try await edits.title(value,token:generation)
                guard titleGeneration == generation else { return }; titleDirty = false
                if native { RecordingController.shared.title = displayTitle }
            } catch is CancellationError {} catch { NSApp.presentError(error) }
        }
    }
}

enum RecordingPageFixture {
    static var enabled: Bool {
        #if DEBUG
        ProcessInfo.processInfo.environment["CASSINI_HOSTED_SCREENSHOTS"] == "1" && LibraryLaunchContext.argument("-CassiniScreenshot") == "recording"
        #else
        false
        #endif
    }
}
