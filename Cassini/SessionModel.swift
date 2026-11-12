// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import CassiniKit
import CassiniLibrary
import Observation
import SwiftUI

/// Everything one document window shows: the file, its player, and the view state.
@MainActor
@Observable
final class SessionModel {
    enum Tab: Hashable { case transcript, summary }

    let file: CassiniFile?
    let readError: String?
    let fileURL: URL?
    let player: PlayerController?
    let manifest: Manifest?
    /// The manifest's speakers, plus one entry per speaker id the transcript names but the manifest lacks.
    private(set) var speakers: [Speaker] = []

    var selectedTranscriptId: String? {
        didSet { if selectedTranscriptId != oldValue { rebuildTimeline() } }
    }
    private(set) var timeline: Timeline?
    private(set) var preparingTranscript = false
    /// Why there is no transcript on screen, when there is none.
    private(set) var transcriptProblem: String?

    var hiddenSpeakers: Set<String> = []
    var tab: Tab = .transcript
    /// Summary task items ticked in this window; the file is read-only, so this lives with the window.
    var tickedSummaryItems: Set<Int> = []
    var searchText = ""
    var follow = true
    /// The user scrolled away while following; a "Jump to current" button offers the way back.
    var followPaused = false
    var showInspector = true
    /// Speakers with a word under the playhead right now.
    private(set) var speakingNow: Set<String> = []

    // Search state the transcript view reports back.
    var matchCount = 0
    var matchIndex = 0

    // Requests to the transcript view, as counters so SwiftUI notices each one.
    var jumpRequest = 0
    var matchStep = (serial: 0, direction: 0)
    var focusSearchRequest = 0

    weak var window: NSWindow?
    /// Retained through file decoding and player teardown, even after a window closes.
    @ObservationIgnored var fileAccessLease: AnyObject?
    /// The transcript view's frame-rate subscriber: time in ms and the current word per speaker.
    @ObservationIgnored var transcriptSink: ((Int, [String: Int]) -> Void)?
    @ObservationIgnored private var lookupHint: [String: Int] = [:]
    @ObservationIgnored private var lastWords: [String: Int] = [:]
    @ObservationIgnored private var timelineTask: Task<Void,Never>?
    @ObservationIgnored private var preparedTimelines: [String:Timeline] = [:]
    @ObservationIgnored private var timelineRequest = UUID()

    init(document: CassiniDocument, url: URL?, fileAccessLease: AnyObject? = nil) {
        self.fileAccessLease = fileAccessLease
        file = document.file
        readError = document.readError
        fileURL = url
        manifest = document.file?.manifest
        let title = manifest?.meeting.title ?? url?.deletingPathExtension().lastPathComponent ?? UXText.text("library.untitled")
        if let url {
            player = PlayerController(url: url, durationMs: manifest?.meeting.durationMs ?? 0, title: title, fileAccessLease: fileAccessLease)
        } else {
            player = nil
        }
        selectedTranscriptId = manifest?.defaultTranscript?.id
        rebuildTimeline()
        player?.tickHandlers.append { [weak self] ms in self?.tick(ms) }
        SessionRegistry.shared.register(self)
    }

    // MARK: Derived display

    var title: String {
        manifest?.meeting.title ?? fileURL?.deletingPathExtension().lastPathComponent ?? UXText.text("library.untitled")
    }

    var subtitle: String {
        var parts: [String] = []
        if let date = recordingDateText { parts.append(date) }
        if let m = manifest {
            parts.append(UXText.text("mac.quicklook.speakerCount",["n":String(m.speakers.count)]))
        }
        if let d = player?.durationMs, d > 0 { parts.append(formatClock(d)) }
        return parts.joined(separator: " · ")
    }

    /// D95: one reader order for the direct-open header and Inspector too.
    var recordingDateText: String? {
        guard let time = file?.meetingTime else { return nil }
        return LibraryFormat(locale:UXText.locale,language:UXText.language).absoluteDate(time)
    }

    static let dateStyle = Date.FormatStyle(date: .abbreviated, time: .omitted)

    static func parseRFC3339(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }

    /// `YYYY-MM-DDTHH:MM:SS` as a Date in UTC, so formatting in UTC reproduces the label's own day.
    static func localLabelDate(_ s: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return f.date(from: s)
    }

    var hasSummary: Bool { manifest?.summaryMarkdown != nil }

    var fileName: String { fileURL?.lastPathComponent ?? "" }

    var hasQuery: Bool { !searchText.trimmingCharacters(in: .whitespaces).isEmpty }

    func color(for speakerId: String) -> NSColor {
        guard let i = speakers.firstIndex(where: { $0.id == speakerId }) else {
            return CassiniTheme.nsSpeakerInk(colourIndex: 0, unnamed: true)
        }
        return CassiniTheme.nsSpeakerInk(colourIndex: i, unnamed: speakers[i].label == nil)
    }

    func label(for speakerId: String) -> String {
        speakers.first { $0.id == speakerId }?.label ?? UXText.text("common.speaker.unnamed",["n":String(speakers.count + 1)])
    }

    // MARK: Transcript

    private func rebuildTimeline() {
        timelineTask?.cancel(); timelineTask = nil
        let request = UUID(); timelineRequest = request
        preparingTranscript = false
        speakers = manifest?.speakers ?? []
        timeline = nil
        transcriptProblem = nil
        lookupHint = [:]
        lastWords = [:]
        guard let file else {
            transcriptProblem = UXText.text("mac.legacy.unreadable")
            return
        }
        switch file.state {
        case .plainAudio:
            transcriptProblem = UXText.text("mac.legacy.noTranscript")
            return
        case .unknownCassiniFormat, .invalidCassiniMetadata:
            transcriptProblem = UXText.text("mac.legacy.transcriptUnreadable")
            return
        default:
            break
        }
        guard let id = selectedTranscriptId, let entry = file.transcripts.first(where: { $0.entry.id == id }) else {
            transcriptProblem = UXText.text("mac.legacy.noTranscript")
            return
        }
        switch entry.load {
        case .available(let t):
            var known = Set(speakers.map(\.id))
            for w in t.items where !known.contains(w.speaker) {
                known.insert(w.speaker)
                // D53.3: an unnamed speaker written in the UI language.
                speakers.append(Speaker(id: w.speaker, label: UXText.text("common.speaker.unnamed",["n":String(speakers.count + 1)])))
            }
            if let prepared = preparedTimelines[id] { timeline = prepared; return }
            preparingTranscript = true
            let bounded = file.manifest?.wordEndsBoundedByAudio == true
            let work = Task.detached(priority:.userInitiated) {
                try Task.checkCancellation()
                let result = try Timeline.preparing(t.items,endsBoundedByAudio:bounded)
                try Task.checkCancellation()
                return result
            }
            timelineTask = Task { [weak self] in
                let result = await withTaskCancellationHandler { try? await work.value } onCancel: { work.cancel() }
                guard !Task.isCancelled, let self, self.timelineRequest == request, let result else { return }
                self.preparedTimelines[id] = result
                self.timeline = result; self.timelineTask = nil; self.preparingTranscript = false
                if let ms = self.player?.currentMs { self.tick(ms) }
            }
        case .unavailable(let f):
            transcriptProblem = UXText.text("mac.legacy.transcriptUnreadable")
        }
    }

    /// Transcripts the inspector can switch between.
    var availableTranscripts: [TranscriptEntry] { file?.transcripts.map(\.entry) ?? [] }

    // MARK: Playback plumbing

    private func tick(_ ms: Int) {
        guard let timeline else { return }
        let words = timeline.currentWords(at: ms, hint: &lookupHint)
        if words != lastWords {
            lastWords = words
            let now = Set(words.keys)
            if now != speakingNow { speakingNow = now }
        }
        transcriptSink?(ms, words)
    }

    /// Seeks and turns following back on, as the design asks of every seek.
    func seek(toMs ms: Int) {
        followPaused = false
        player?.seek(toMs: ms)
    }

    func seek(toWord index: Int) {
        guard let w = timeline?.words[index] else { return }
        seek(toMs: w.startMs)
    }

    /// From the summary: switch to the transcript and seek.
    func goToTranscript(ms: Int) {
        tab = .transcript
        seek(toMs: ms)
    }

    func jumpToCurrent() {
        followPaused = false
        follow = true
        jumpRequest += 1
    }

    func findNext() { matchStep = (matchStep.serial + 1, 1) }
    func findPrevious() { matchStep = (matchStep.serial + 1, -1) }

    /// The window is closing: stop the audio for good.
    func close() {
        timelineTask?.cancel(); timelineTask = nil; timelineRequest = UUID(); preparingTranscript = false
        player?.shutDown()
        transcriptSink = nil
    }

    func showInFinder() {
        guard let fileURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([fileURL])
    }
}

// MARK: - Focused values for menu commands

struct SessionFocusedKey: FocusedValueKey {
    typealias Value = SessionModel
}

extension FocusedValues {
    var session: SessionModel? {
        get { self[SessionFocusedKey.self] }
        set { self[SessionFocusedKey.self] = newValue }
    }
}
