// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import CassiniLibrary
import CassiniPlayback
import Observation

@MainActor @Observable final class MeetingNavigation {
    static let shared = MeetingNavigation()
    var detail: MeetingDetailModel?
    private(set) var loading = false
    @ObservationIgnored private var readTask: Task<Void, Never>?
    @ObservationIgnored var openLibrary: (() -> Void)? = { ApplicationWindows.library() }
    func open(_ meeting: LibraryMeeting, autoplay: Bool = false, frozen: Bool = false) {
        guard !LibraryMoveCoordinator.shared.busy || meeting.state.lifecycle != .saved else { return }
        if LibrarySearchModel.shared.visible { LibrarySearchModel.shared.close() }
        readTask?.cancel(); loading = false
        if detail?.meeting.libraryKey == meeting.libraryKey {
            detail?.meeting = meeting
            if autoplay, detail?.isPlaying != true { detail?.toggle() }
        } else {
            detail?.close()
            detail = MeetingDetailModel(meeting: meeting, frozen: frozen)
            if autoplay { detail?.toggle() }
        }
        openLibrary?()
    }
    func openFile(_ url: URL, autoplay: Bool) {
        if detail?.fileURL == url.standardizedFileURL {
            if autoplay, detail?.isPlaying != true { detail?.toggle() }
            openLibrary?(); return
        }
        back(); loading = true; openLibrary?()
        let lease = FileAccessLease(url)
        readTask = Task { [weak self] in
            do {
                let task = Task.detached { [lease] in
                    defer { withExtendedLifetime(lease) {} }
                    try Task.checkCancellation()
                    return try CassiniDocument(url: lease.url)
                }
                let document = try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
                try Task.checkCancellation()
                guard let file = document.file else { throw CocoaError(.fileReadCorruptFile) }
                guard let self else { return }
                self.detail = MeetingDetailModel(meeting: MeetingPresentation.external(file, url: url), fileURL: url, lease: lease)
                self.loading = false; self.readTask = nil
                if autoplay { self.detail?.toggle() }
            } catch {
                guard !Task.isCancelled, let self else { return }
                self.loading = false; self.readTask = nil
                NSApp.presentError(error)
            }
        }
    }
    func update(_ meetings: [LibraryMeeting], offline: Bool) {
        guard let detail, detail.fileURL == nil else { return }
        // An outage only stops playback: the page stays, and so does its transcript (#118 r2).
        guard !offline, let meeting = meetings.first(where: { $0.libraryKey == detail.meeting.libraryKey }) else { detail.suspend(); return }
        if meeting.audioFiles != detail.meeting.audioFiles {
            detail.close(); self.detail = MeetingDetailModel(meeting: meeting); return
        }
        detail.meeting = meeting
        detail.resumePreparation()
        detail.reconcile(offline:offline)
    }
    func captureBeganSaving(at folder: URL) {
        if let detail, detail.fileURL == nil, detail.meeting.folder.standardizedFileURL.path == folder.standardizedFileURL.path { back() }
    }
    func back() { readTask?.cancel(); readTask = nil; loading = false; detail?.close(); detail = nil }
}

@MainActor @Observable final class MeetingDetailModel {
    var meeting: LibraryMeeting {
        didSet {
            if meeting.transcriptItems != oldValue.transcriptItems || meeting.speakers.map(\.id) != oldValue.speakers.map(\.id) {
                prepareTurns()
                shares = MeetingPresentation.shares(meeting)
            }
        }
    }
    private(set) var turns: [MeetingPresentation.Turn] = []
    /// #118 review: turns are prepared off the main actor; a newer transcript, or closing the
    /// page, cancels a preparation still running, so its result never lands.
    @ObservationIgnored private var preparation: TurnPreparation?
    private(set) var shares: [String: Int] = [:]
    let fileURL: URL?
    let audio = SessionPlayback()
    private let fileAccessLease: AnyObject?
    private let frozen: Bool
    private var fixturePosition = 192_000
    private var fixturePlaying = true
    init(meeting: LibraryMeeting, fileURL: URL? = nil, lease: AnyObject? = nil, frozen: Bool = false) {
        self.meeting = meeting; self.fileURL = fileURL?.standardizedFileURL; self.frozen = frozen
        fileAccessLease = lease
        shares = MeetingPresentation.shares(meeting)
        audio.onFailure = { NSApp.presentError($0) }
        prepareTurns()
    }
    private func prepareTurns() {
        // Screenshot and self-test fixtures render a fixed frame: prepared in place.
        if frozen { turns = MeetingPresentation.turns(meeting.transcriptItems); return }
        if preparation == nil { preparation = TurnPreparation { [weak self] in self?.turns = $0 } }
        preparation?.request(meeting.transcriptItems)
    }
    /// After a Library update: a preparation an outage cancelled starts again.
    func resumePreparation() { preparation?.resume() }
    // Received audio uses the same asynchronous composition/transport as a
    // recorded meeting. Opening a page performs no synchronous demux or engine
    // setup on the UI thread. This private transport input changes no metadata.
    private var playbackMeeting: LibraryMeeting {
        guard meeting.state.origin == .received else { return meeting }
        var source = meeting; source.state.origin = .own
        source.audioTracks = meeting.audioFiles.map { .init(url:$0,startOffsetMs:0) }
        return source
    }
    var isPlaying: Bool { frozen ? fixturePlaying : audio.isPlaying }
    var positionMs: Int { frozen ? fixturePosition : Int(audio.positionMs) }
    var durationMs: Int { Int(meeting.durationMs ?? 0) }
    var canPlay: Bool { frozen || playbackMeeting.canPlaySession }
    var rate: Double { Double(audio.rate) }
    func toggle() {
        if frozen { fixturePlaying.toggle(); return }
        PlayerController.pauseActive(); audio.toggle(playbackMeeting)
    }
    func seek(_ ms: Int) {
        let ms = max(0, min(durationMs, ms))
        if frozen { fixturePosition = ms; return }
        audio.prepare(playbackMeeting); audio.seek(toMs: Double(ms))
    }
    func playFrom(_ ms: Int) {
        let ms = max(0,min(durationMs,ms))
        if frozen { fixturePosition = ms; fixturePlaying = true; return }
        PlayerController.pauseActive()
        audio.play(playbackMeeting,fromMs:Double(ms))
    }
    func skip(_ seconds: Int) { seek(positionMs + seconds * 1000) }
    func cycleRate() {
        let rates: [Float] = [1, 1.25, 1.5, 2, 0.75]
        audio.rate = rates[((rates.firstIndex(of: audio.rate) ?? 0) + 1) % rates.count]
    }
    func reconcile(offline: Bool) { audio.reconcile(playbackMeeting,offline:offline) }
    /// A Library outage: playback stops and any preparation pauses, to resume on recovery.
    func suspend() { preparation?.cancel(); audio.stop() }
    func close() { preparation?.cancel(); preparation = nil; audio.stop() }
}
