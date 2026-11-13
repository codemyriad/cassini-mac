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
    func open(_ meeting: LibraryMeeting, autoplay: Bool = false, frozen: Bool = false, activate: Bool = true) {
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
        if activate { openLibrary?() }
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
    var namingSpeakerID:String?
    var meeting: LibraryMeeting {
        didSet {
            if meeting.summaryMarkdown == nil { tab = .transcript }
            if let id=namingSpeakerID {namingSpeakerID=meeting.speaker(for:id)?.id}
            if MeetingPresentation.turnInputsChanged(from:oldValue,to:meeting) {
                prepareTurns()
                shares = MeetingPresentation.shares(meeting)
            }
        }
    }
    let find = MeetingFindModel()
    enum Tab: Hashable { case summary, transcript }
    var tab: Tab
    var tickedSummaryItems: Set<Int> = []
    func focusFind() { tab = .transcript; find.requestFocus() }
    var compactHeader = false
    private(set) var turnsRevision = 0
    var revealPositionMs: Int64?
    var revealTurnID: Int?
    private(set) var turns: [MeetingPresentation.Turn] = []
    private(set) var listeningTurns: [SpeakerTurn] = []
    private(set) var timelineReadout = TimelineReadout()
    private(set) var transcriptListening = TranscriptListening()
    private(set) var followRevision = 0
    @ObservationIgnored private var transcriptFollow = TranscriptFollow()
    var canFollowTranscript: Bool { transcriptFollow.allowsFollow(at:ProcessInfo.processInfo.systemUptime) }
    func handScrolledTranscript() { transcriptFollow.handScrolled(at:ProcessInfo.processInfo.systemUptime) }
    private func resumeTranscriptFollow() { transcriptFollow.stepped(); followRevision += 1 }
    var listeningHost: Int? { listen.turn.flatMap { transcriptListening.host(forListening:$0.index) } }
    func listenFromReadingTurn(_ id: Int) {
        guard frozen || MeetingNavigation.shared.detail === self else { return }
        guard turns.indices.contains(id), let target = transcriptListening.listeningIndex(forReading:id,at:Int64(positionMs)) else { return }
        let speaker = turns[id].speaker
        guard let local = listen.turns(of:speaker).firstIndex(where:{ $0.index == target }) else { return }
        if frozen { previewListening(speaker,index:local); resumeTranscriptFollow() }
        else { _ = listenTo(speaker,turnIndex:local) }
    }
    /// #118 review: turns are prepared off the main actor; a newer transcript, or closing the
    /// page, cancels a preparation still running, so its result never lands.
    @ObservationIgnored private var preparation: TurnPreparation?
    private(set) var shares: [String: Int] = [:]
    let fileURL: URL?
    let speakerSample:SpeakerSample
    let audio: SessionPlayback
    let listen: ListenController
    private let fileAccessLease: AnyObject?
    private let frozen: Bool
    private var fixturePosition = 192_000
    private var fixturePlaying = true
    init(meeting: LibraryMeeting, fileURL: URL? = nil, lease: AnyObject? = nil, frozen: Bool = false) {
        var meeting = meeting
        #if DEBUG
        if frozen, ProcessInfo.processInfo.environment["CASSINI_HOSTED_SCREENSHOTS"] == "1",
           LibraryLaunchContext.argument("-CassiniSummaryFixture") == "YES" {
            meeting.summaryMarkdown = "# Meeting summary\n\nReview the budget and agree on the next steps.\n\n- [ ] Share the updated figures.\n- Review the decision at 00:03:12."
        }
        #endif
        self.meeting = meeting; self.fileURL = fileURL?.standardizedFileURL; self.frozen = frozen
        tab = meeting.summaryMarkdown == nil ? .transcript : .summary
        let audio = SessionPlayback(); self.audio = audio; listen = ListenController(playback:audio); speakerSample=SpeakerSample(playback:audio)
        fileAccessLease = lease
        shares = MeetingPresentation.shares(meeting)
        audio.onFailure = { NSApp.presentError($0) }
        prepareTurns()
    }
    private func prepareTurns() {
        // Screenshot and self-test fixtures render a fixed frame: prepared in place.
        if frozen {
            turns = MeetingPresentation.turns(meeting.transcriptItems,gaps:meeting.speakerGaps,endsBoundedByAudio:meeting.wordEndsBoundedByAudio)
            turnsRevision &+= 1
            listeningTurns = meeting.speakerTurns; listen.setTurns(listeningTurns)
            timelineReadout = TimelineReadout(items:meeting.transcriptItems)
            transcriptListening = TranscriptListening(rows:turns,turns:listeningTurns)
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
        preparation?.request(meeting.transcriptItems,gaps:meeting.speakerGaps,endsBoundedByAudio:meeting.wordEndsBoundedByAudio)
    }
    private func acceptTurns(_ turns: [MeetingPresentation.Turn]) {
        self.turns = turns
        turnsRevision &+= 1
        if let preparation {
            listeningTurns = preparation.speakerTurns; listen.setTurns(listeningTurns)
            timelineReadout = preparation.timelineReadout
            transcriptListening = preparation.transcriptListening
        }
    }
    @discardableResult func listenTo(_ speaker: String, turnIndex: Int? = nil) -> Bool {
        guard !frozen else { return false }
        speakerSample.cancel()
        PlayerController.pauseActive()
        let accepted = listen.start(speaker,in:playbackMeeting,turnIndex:turnIndex)
        if accepted { resumeTranscriptFollow() }; return accepted
    }
    func toggleSpeakerListening(_ speaker: String) {
        if let current = listen.speaker, (meeting.mergedInto[current] ?? current) == (meeting.mergedInto[speaker] ?? speaker) { stopListening() }
        else { listenTo(speaker) }
    }
    func speakerName(_ id: String) -> String {
        meeting.speaker(for:id)?.displayName(language:UXText.language,locale:UXText.locale) ?? UXText.text("common.speaker.unnamed",["n":"1"])
    }
    var listeningPresentation: ListeningBarPresentation? {
        guard let turn = listen.turn, let first = listen.turns(of:turn.speaker).first else { return nil }
        let name = speakerName(turn.speaker)
        let previous = turn.index > 0 && listeningTurns.indices.contains(turn.index-1) ? listeningTurns[turn.index-1] : nil
        return .init(name:name,turn:turn,previous:previous,index:listen.index,count:listen.count,firstStartMs:first.startMs,language:UXText.language,locale:UXText.locale)
    }
    var canUseListeningShortcuts: Bool { canUseListeningShortcuts(in:NSApp.keyWindow) }
    // Commands observe model state only; AppKit focus is checked when invoked.
    var canUseListeningCommands: Bool { listen.active && canUseTranscriptCommands }
    private var canUseTranscriptCommands: Bool {
        canPlay && !find.focused && MeetingNavigation.shared.detail === self && !LibrarySearchModel.shared.visible &&
        MeetingRenameCoordinator.shared.presentation == nil && !MeetingExportCoordinator.shared.showing &&
        !RecordingDetailsCoordinator.shared.showing && !RecordCoordinator.shared.showingFirst &&
        CompanionSetup.shared.presenter != .library && !RecordingConfirmation.active
    }
    func canUseListeningShortcuts(in window: NSWindow?) -> Bool { listen.active && canUseTranscriptShortcuts(in:window) }
    var canUseTranscriptShortcuts: Bool { canUseTranscriptShortcuts(in:NSApp.keyWindow) }
    func canUseTranscriptShortcuts(in window: NSWindow?) -> Bool {
        guard canUseTranscriptCommands,
              let window, window.accessibilityIdentifier() == "cassini-library-window",
              window.attachedSheet == nil, NSApp.modalWindow == nil else { return false }
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
        if accepted { resumeTranscriptFollow() }
        if accepted, before == listen.turn?.index { announceListeningTurn() }
    }
    func stepListeningSpeaker(_ direction: Int) {
        let before = listen.speaker
        if frozen {
            if let speaker = listen.speakerStepTarget(direction,order:meeting.speakers.map(\.id)) { previewListening(speaker) }
        } else { listen.stepSpeaker(direction,order:meeting.speakers.map(\.id)) }
        if before != listen.speaker { resumeTranscriptFollow() }
    }
    func playListeningAgain() {
        let before = listen.turn?.index
        if frozen { if let speaker = listen.speaker { previewListening(speaker); resumeTranscriptFollow() } }
        else if listen.playAgain() {
            resumeTranscriptFollow()
            if before == listen.turn?.index { announceListeningTurn() }
        }
    }
    func stopListening() { resetListeningAnnouncement(); if frozen { fixturePlaying = false }; listen.stopPlayback() }
    private func previewListening(_ speaker: String, index: Int = 0, finished: Bool = false) {
        #if DEBUG
        listen.preview(speaker,index:index,finished:finished)
        if let turn = listen.turn { fixturePosition = Int(finished ? turn.endMs+500 : turn.startMs); fixturePlaying = !finished }
        #endif
    }
    @ObservationIgnored private var announcedSpeaker: String?
    func resetListeningAnnouncement() { announcedSpeaker = nil }
    func announceListeningTurn() {
        guard listen.active, MeetingNavigation.shared.detail === self, let presentation = listeningPresentation else { return }
        let message = announcedSpeaker == listen.speaker ? presentation.announcement : presentation.speakerAnnouncement
        #if DEBUG
        if let sink = Self.announcementForSelfTest {
            announcedSpeaker = listen.speaker; sink(message); return
        }
        #endif
        guard !frozen, NSWorkspace.shared.isVoiceOverEnabled,
              let view = NSApp.windows.first(where: { $0.accessibilityIdentifier() == "cassini-library-window" && $0.isVisible })?.contentView else { return }
        announcedSpeaker = listen.speaker
        NSAccessibility.post(element:view,notification:.announcementRequested,userInfo:[
            .announcement:message,.priority:NSAccessibilityPriorityLevel.low.rawValue])
    }
    #if DEBUG
    /// ListeningSelfTest captures the production message without enabling VoiceOver.
    static var announcementForSelfTest: ((String) -> Void)?
    /// MeetingPreparationSelfTest controls when off-main preparation proceeds.
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
        speakerSample.cancel()
        if frozen { fixturePlaying.toggle(); return }
        PlayerController.pauseActive(); audio.toggle(playbackMeeting)
    }
    func seek(_ ms: Int) {
        speakerSample.cancel()
        let ms = max(0, min(durationMs, ms))
        if frozen { fixturePosition = ms; return }
        audio.seek(playbackMeeting,toMs:Double(ms))
    }
    func playFrom(_ ms: Int) {
        speakerSample.cancel()
        let ms = max(0,min(durationMs,ms))
        if frozen { fixturePosition = ms; fixturePlaying = true; return }
        PlayerController.pauseActive()
        audio.play(playbackMeeting,fromMs:Double(ms))
    }
    func playSpeakerSample(_ range:Range<Int64>) {
        guard !frozen,MeetingNavigation.shared.detail === self else {return}
        stopListening();PlayerController.pauseActive()
        speakerSample.play(playbackMeeting,range:range)
    }
    func skip(_ seconds: Int) { seek(positionMs + seconds * 1000) }
    func cycleRate() {
        let rates: [Float] = [1, 1.25, 1.5, 2, 0.75]
        audio.rate = rates[((rates.firstIndex(of: audio.rate) ?? 0) + 1) % rates.count]
    }
    func reconcile(offline: Bool) { audio.reconcile(playbackMeeting,offline:offline) }
    /// A Library outage: playback stops and any preparation pauses, to resume on recovery.
    func suspend() { speakerSample.cancel(); resetListeningAnnouncement(); preparation?.cancel(); listen.pageChanged() }
    func close() { speakerSample.cancel(); resetListeningAnnouncement(); preparation?.cancel(); preparation = nil; listen.pageChanged() }
}
