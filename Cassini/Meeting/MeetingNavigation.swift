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
    @ObservationIgnored var openLibrary: (() -> Void)?
    func open(_ meeting: LibraryMeeting, autoplay: Bool = false, frozen: Bool = false) {
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
        guard !offline, let meeting = meetings.first(where: { $0.libraryKey == detail.meeting.libraryKey }) else { detail.close(); return }
        if meeting.audioFiles != detail.meeting.audioFiles {
            detail.close(); self.detail = MeetingDetailModel(meeting: meeting); return
        }
        detail.meeting = meeting
        detail.audio.reconcile(meeting, offline: offline)
    }
    func back() { readTask?.cancel(); readTask = nil; loading = false; detail?.close(); detail = nil }
}

@MainActor @Observable final class MeetingDetailModel {
    var meeting: LibraryMeeting {
        didSet {
            if meeting.transcriptItems != oldValue.transcriptItems || meeting.speakers.map(\.id) != oldValue.speakers.map(\.id) {
                turns = MeetingPresentation.turns(meeting.transcriptItems)
                shares = MeetingPresentation.shares(meeting)
            }
        }
    }
    private(set) var turns: [MeetingPresentation.Turn] = []
    private(set) var shares: [String: Int] = [:]
    let fileURL: URL?
    let audio = SessionPlayback()
    private let filePlayer: PlayerController?
    private let frozen: Bool
    private var fixturePosition = 192_000
    private var fixturePlaying = true
    init(meeting: LibraryMeeting, fileURL: URL? = nil, lease: AnyObject? = nil, frozen: Bool = false) {
        self.meeting = meeting; self.fileURL = fileURL?.standardizedFileURL; self.frozen = frozen
        let playable = fileURL ?? (meeting.state.origin == .received ? meeting.audioFiles.first : nil)
        filePlayer = !frozen ? playable.map { PlayerController(url: $0, durationMs: Int(meeting.durationMs ?? 0), title: meeting.title ?? UXText.text("library.untitled"), fileAccessLease: lease) } : nil
        turns = MeetingPresentation.turns(meeting.transcriptItems); shares = MeetingPresentation.shares(meeting)
        audio.onFailure = { NSApp.presentError($0) }
    }
    var isPlaying: Bool { frozen ? fixturePlaying : filePlayer?.isPlaying ?? audio.isPlaying }
    var positionMs: Int { frozen ? fixturePosition : filePlayer?.currentMs ?? Int(audio.positionMs) }
    var durationMs: Int { Int(meeting.durationMs ?? Int64(filePlayer?.durationMs ?? 0)) }
    var canPlay: Bool { frozen || filePlayer != nil || meeting.canPlaySession }
    var rate: Double { filePlayer?.speed ?? Double(audio.rate) }
    func toggle() {
        if frozen { fixturePlaying.toggle(); return }
        if let filePlayer { filePlayer.toggle() }
        else { PlayerController.pauseActive(); audio.toggle(meeting) }
    }
    func seek(_ ms: Int) {
        let ms = max(0, min(durationMs, ms))
        if frozen { fixturePosition = ms; return }
        if let filePlayer { filePlayer.seek(toMs: ms) }
        else { audio.prepare(meeting); audio.seek(toMs: Double(ms)) }
    }
    func skip(_ seconds: Int) { seek(positionMs + seconds * 1000) }
    func cycleRate() {
        if let filePlayer { filePlayer.cycleSpeed() }
        else {
            let rates: [Float] = [1, 1.25, 1.5, 2, 0.75]
            audio.rate = rates[((rates.firstIndex(of: audio.rate) ?? 0) + 1) % rates.count]
        }
    }
    func close() { audio.stop(); filePlayer?.shutDown() }
}
