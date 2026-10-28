// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import CassiniLibrary
import CassiniRecording
import CassiniWhistle
import Observation

private actor RecordingEdits {
    let directory: URL
    let id: UUID
    private var titleToken = 0, notesToken = 0
    init(directory: URL, id: UUID) { self.directory = directory; self.id = id }
    func title(_ title: String, token: Int) throws {
        guard token > titleToken else { return }; titleToken = token
        try MeetingMetadataWriter(directory: directory, id: id).transaction { metadata in
            metadata["title"] = title.isEmpty ? NSNull() : title as Any
            metadata["titleSource"] = title.isEmpty ? "meeting-window" : "user"
        }
    }
    func notes(_ notes: [RecordingNotes.Line], token: Int) throws {
        guard token > notesToken else { return }; notesToken = token
        try MeetingMetadataWriter(directory: directory, id: id).transaction { metadata in
            metadata["notes"] = notes.compactMap { note -> [String:Any]? in
                guard let time = note.atMs, !note.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
                return ["atMs":time,"text":note.text]
            }
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
        editors = editors.filter { $0.value.titleTask != nil || $0.value.notesTask != nil }
        let model = RecordingPageModel(meeting)
        editors[meeting.folder.path] = model; return model
    }
    static var hasPendingEdits: Bool { editors.values.contains { $0.titleTask != nil || $0.notesTask != nil } }
    static func flushAll() async {
        let models = Array(editors.values)
        for model in models { model.flush() }
        for model in models { await model.titleTask?.value; await model.notesTask?.value }
    }
    private(set) var meeting: LibraryMeeting
    var title: String
    var notesText: String
    var voiceCount: Int = 0
    private(set) var frozen = false
    @ObservationIgnored private let edits: RecordingEdits
    @ObservationIgnored private var notes: RecordingNotes
    @ObservationIgnored private var titleTask: Task<Void,Never>?
    @ObservationIgnored private var notesTask: Task<Void,Never>?
    @ObservationIgnored private var titleGeneration = 0
    @ObservationIgnored private var notesGeneration = 0
    @ObservationIgnored private var titleDirty = false
    @ObservationIgnored private var notesDirty = false
    @ObservationIgnored private var voiceTask: Task<Void,Never>?
    @ObservationIgnored private var sourceGeneration = 0
    @ObservationIgnored private var liveAnchor = ProcessInfo.processInfo.systemUptime
    @ObservationIgnored private var liveElapsed: Int64 = 0
    private init(_ meeting: LibraryMeeting) {
        self.meeting = meeting; title = meeting.title ?? UXText.text("library.untitled")
        edits = RecordingEdits(directory: meeting.folder, id: meeting.id)
        let initial = meeting.notes.flatMap { note in note.text.components(separatedBy:"\n").map { RecordingNotes.Line(atMs:note.atMs,text:$0) } }
        let displayed = initial.map { UXText.text("recording.notes.entry", ["position":LibraryFormat.position($0.atMs ?? 0),"text":$0.text]) }.joined(separator: "\n")
        notesText = displayed
        notes = RecordingNotes(lines:initial,displayed:displayed)
        liveElapsed = meeting.state.liveMs ?? meeting.durationMs ?? 0
        #if DEBUG
        frozen = LibraryLaunchContext.current.screenshot
        #endif
        if frozen { voiceCount = 4 } // Published Recording board's frozen source-count state.
        else { refreshVoices() }
    }
    func update(_ meeting: LibraryMeeting) {
        let elapsed = elapsedMs
        self.meeting = meeting
        liveElapsed = max(elapsed,meeting.state.liveMs ?? 0); liveAnchor = ProcessInfo.processInfo.systemUptime
        if !frozen { refreshVoices() }
    }
    private func refreshVoices() {
        guard meeting.isBrowserCapture else { voiceCount = 0; return }
        voiceTask?.cancel(); sourceGeneration += 1
        let revision = sourceGeneration, folder = meeting.folder
        voiceTask = Task { [weak self] in
            let count = await Task.detached {
                guard let data = try? WhistleIO.readRegular(folder.appendingPathComponent("session.json"),maximum:1_048_576),
                      let manifest = try? RecordingLoader.decode(data) else { return 0 }
                return manifest.tracks.filter { ["remote","media","tab"].contains($0.kind) && $0.ended != true }.count
            }.value
            guard let self, !Task.isCancelled, revision == self.sourceGeneration else { return }
            self.voiceCount = count; self.voiceTask = nil
        }
    }
    var native: Bool { RecordingController.shared.directory?.lastPathComponent == meeting.libraryKey }
    var elapsedMs: Int64 {
        if native { return RecordingController.shared.elapsedMs }
        if frozen || meeting.state.lifecycle != .recording { return meeting.state.liveMs ?? liveElapsed }
        return liveElapsed + Int64(max(0,ProcessInfo.processInfo.systemUptime - liveAnchor) * 1000)
    }
    var microphone: Float { native ? RecordingController.shared.levels["microphone",default:0] : 0 }
    var output: Float { native ? RecordingController.shared.levels["output",default:0] : (frozen ? 0.58 : 0) }
    var microphoneSilent: Bool { native ? RecordingController.shared.microphoneSilent : frozen }
    var displayTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? UXText.text("library.untitled") : title }
    func changeTitle() {
        title = String(String.UnicodeScalarView(title.unicodeScalars.prefix(500)))
        guard !frozen else { return }
        // Publish the current user input immediately; persistence is debounced.
        // Older writes cannot replace this value after a later binding update.
        if native { RecordingController.shared.title = displayTitle }
        titleDirty = true; scheduleTitle()
    }
    func changeNotes() {
        guard !frozen else { return }
        let undo = (NSApp.keyWindow?.firstResponder as? NSTextView)?.undoManager
        let restoration: RecordingNotes.Restoration? = undo?.isUndoing == true ? .undo : (undo?.isRedoing == true ? .redo : nil)
        notes.edit(notesText,atMs:elapsedMs,restoration:restoration) { LibraryFormat.position($0) + "  " }
        notesDirty = true; scheduleNotes()
    }
    func formatNotes() {
        notesText = notes.lines.map { note in
            guard let at = note.atMs else { return note.text }
            return UXText.text("recording.notes.entry", ["position":LibraryFormat.position(at),"text":note.text])
        }.joined(separator:"\n")
        notes.reformat(notesText)
    }
    func flush() { if titleDirty { scheduleTitle(immediate:true) }; if notesDirty { scheduleNotes(immediate:true) } }
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
    private func scheduleNotes(immediate: Bool = false) {
        notesTask?.cancel(); notesGeneration += 1; let generation = notesGeneration, value = notes.lines
        notesTask = Task {
            defer { if notesGeneration == generation { notesTask = nil } }
            do {
                if !immediate { try await Task.sleep(for:.milliseconds(400)) }
                try Task.checkCancellation(); try await edits.notes(value,token:generation)
                if notesGeneration == generation { notesDirty = false }
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
