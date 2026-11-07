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
            if MeetingPresentation.turnInputsChanged(from:oldValue,to:meeting) {
                prepareTurns()
                shares = MeetingPresentation.shares(meeting)
            }
        }
    }
    private(set) var turns: [MeetingPresentation.Turn] = []
    private(set) var listeningTurns: [SpeakerTurn] = []
    /// #118 review: turns are prepared off the main actor; a newer transcript, or closing the
    /// page, cancels a preparation still running, so its result never lands.
    @ObservationIgnored private var preparation: TurnPreparation?
    private(set) var shares: [String: Int] = [:]
    let fileURL: URL?
    let audio: SessionPlayback
    let listen: ListenController
    private let fileAccessLease: AnyObject?
    private let frozen: Bool
    private var fixturePosition = 192_000
    private var fixturePlaying = true
    init(meeting: LibraryMeeting, fileURL: URL? = nil, lease: AnyObject? = nil, frozen: Bool = false) {
        self.meeting = meeting; self.fileURL = fileURL?.standardizedFileURL; self.frozen = frozen
        let audio = SessionPlayback(); self.audio = audio; listen = ListenController(playback:audio)
        fileAccessLease = lease
        shares = MeetingPresentation.shares(meeting)
        audio.onFailure = { NSApp.presentError($0) }
        prepareTurns()
    }
    private func prepareTurns() {
        // Screenshot and self-test fixtures render a fixed frame: prepared in place.
        if frozen {
            turns = MeetingPresentation.turns(meeting.transcriptItems,gaps:meeting.speakerGaps)
            listeningTurns = meeting.speakerTurns; listen.setTurns(listeningTurns)
            #if DEBUG
            if ProcessInfo.processInfo.environment["CASSINI_HOSTED_SCREENSHOTS"] == "1",
               let phase = LibraryLaunchContext.argument("-CassiniListeningPreview"), ["playing","finished"].contains(phase),
               let speaker = LibraryLaunchContext.argument("-CassiniListeningSpeaker") ?? meeting.speakers.first?.id {
                previewListening(speaker,index:phase == "finished" ? listen.turns(of:speaker).count-1 : 0,finished:phase == "finished")
            }
            #endif
            return
        }
        if preparation == nil {
            #if DEBUG
            if let prepare = Self.preparerForSelfTest {
                preparation = TurnPreparation(prepare:prepare) { [weak self] in self?.acceptTurns($0) }
            }
            #endif
            if preparation == nil { preparation = TurnPreparation { [weak self] in self?.acceptTurns($0) } }
        }
        preparation?.request(meeting.transcriptItems,gaps:meeting.speakerGaps)
    }
    private func acceptTurns(_ turns: [MeetingPresentation.Turn]) {
        self.turns = turns
        if let preparation { listeningTurns = preparation.speakerTurns; listen.setTurns(listeningTurns) }
    }
    @discardableResult func listenTo(_ speaker: String, turnIndex: Int? = nil) -> Bool {
        guard !frozen else { return false }
        PlayerController.pauseActive()
        return listen.start(speaker,in:playbackMeeting,turnIndex:turnIndex)
    }
    func toggleSpeakerListening(_ speaker: String) {
        if listen.speaker == speaker { stopListening() }
        else { listenTo(speaker) }
    }
    var listeningPresentation: ListeningBarPresentation? {
        guard let turn = listen.turn else { return nil }
        let name = meeting.speakers.first { $0.id == turn.speaker }?.displayName ?? UXText.text("common.speaker.unnamed",["n":"1"])
        let previous = turn.index > 0 && listeningTurns.indices.contains(turn.index-1) ? listeningTurns[turn.index-1] : nil
        return .init(name:name,turn:turn,previous:previous,index:listen.index,count:listen.count,language:UXText.language,locale:UXText.locale)
    }
    var canUseListeningShortcuts: Bool { canUseListeningShortcuts(in:NSApp.keyWindow) }
    func canUseListeningShortcuts(in window: NSWindow?) -> Bool {
        guard listen.active, MeetingNavigation.shared.detail === self, !LibrarySearchModel.shared.visible,
              let window, window.accessibilityIdentifier() == "cassini-library-window",
              window.attachedSheet == nil, NSApp.modalWindow == nil,
              MeetingRenameCoordinator.shared.presentation == nil, !MeetingExportCoordinator.shared.showing,
              !RecordingDetailsCoordinator.shared.showing, !RecordCoordinator.shared.showingFirst,
              CompanionSetup.shared.presenter != .library, !RecordingConfirmation.active else { return false }
        return (window.firstResponder as? NSTextView)?.isEditable != true && (window.firstResponder as? NSTextField)?.isEditable != true
    }
    func canStepListeningTurn(_ direction: Int) -> Bool {
        guard direction == -1 || direction == 1 else { return false }
        _ = positionMs // Observe the clock as well as the selected turn after a manual seek.
        if frozen { return listen.active && (0..<listen.count).contains(listen.index+direction) }
        return listen.stepTarget(direction) != nil
    }
    func canStepListeningSpeaker(_ direction: Int) -> Bool {
        listen.speakerStepTarget(direction,order:meeting.speakers.map(\.id)) != nil
    }
    func stepListeningTurn(_ direction: Int) {
        let before = listen.turn?.index
        let accepted: Bool
        if frozen {
            accepted = canStepListeningTurn(direction)
            if accepted, let speaker = listen.speaker { previewListening(speaker,index:listen.index+direction) }
        } else if direction == 1 { accepted = listen.nextTurn() }
        else if direction == -1 { accepted = listen.previousTurn() }
        else { accepted = false }
        // A playhead-relative step can reselect the displayed upcoming turn in its lead-in.
        if accepted, before == listen.turn?.index { announceListeningTurn() }
    }
    func stepListeningSpeaker(_ direction: Int) {
        if frozen {
            if let speaker = listen.speakerStepTarget(direction,order:meeting.speakers.map(\.id)) { previewListening(speaker) }
        } else { listen.stepSpeaker(direction,order:meeting.speakers.map(\.id)) }
    }
    func playListeningAgain() {
        let before = listen.turn?.index
        if frozen { if let speaker = listen.speaker { previewListening(speaker) } }
        else if listen.playAgain(), before == listen.turn?.index { announceListeningTurn() }
    }
    func stopListening() { if frozen { fixturePlaying = false }; listen.stopPlayback() }
    private func previewListening(_ speaker: String, index: Int = 0, finished: Bool = false) {
        #if DEBUG
        listen.preview(speaker,index:index,finished:finished)
        if let turn = listen.turn { fixturePosition = Int(finished ? turn.endMs+500 : turn.startMs); fixturePlaying = !finished }
        #endif
    }
    func announceListeningTurn() {
        guard !frozen, canUseListeningShortcuts, NSWorkspace.shared.isVoiceOverEnabled, let presentation = listeningPresentation,
              let view = NSApp.keyWindow?.contentView else { return }
        NSAccessibility.post(element:view,notification:.announcementRequested,userInfo:[
            .announcement:presentation.announcement,.priority:NSAccessibilityPriorityLevel.low.rawValue])
    }
    #if DEBUG
    /// MeetingPreparationSelfTest: a gated preparer, so the proof controls when work proceeds.
    static var preparerForSelfTest: TurnPreparation.Prepare?
    #endif
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
    func suspend() { preparation?.cancel(); listen.pageChanged() }
    func close() { preparation?.cancel(); preparation = nil; listen.pageChanged() }
}
