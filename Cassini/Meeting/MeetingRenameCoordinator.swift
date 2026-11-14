// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import Observation
import CassiniLibrary

@MainActor @Observable final class MeetingRenameCoordinator {
    enum Presentation { case sheet, title, speakers }
    static let shared = MeetingRenameCoordinator()
    var presentation: Presentation?
    var name = ""
    private var voiceChoice=SpeakerVoiceChoice(existing:false)
    var rememberVoice:Bool {
        get { voiceChoice.remember }
        set { voiceChoice.choose(newValue) }
    }
    private(set) var voiceChangeFailed=false
    var canChangeRememberVoice:Bool {
        guard !working, !SavedVoicesController.shared.readOnly else { return false }
        return voiceEnrollment != nil || meeting.flatMap { meeting in
            speakerID.flatMap { SavedVoicesController.shared.snapshot?.voiceID(meeting:meeting.folder.lastPathComponent,speaker:$0) }
        } != nil
    }
    var savedVoiceID:String?
    private(set) var voiceEnrollment:SavedVoicesController.TranscriptEnrollment?
    private(set) var voicePreparationFailed=false
    struct VoiceCandidate:Identifiable,Sendable { let voice:SavedVoice;let score:Float?;var id:String {voice.id} }
    private(set) var voiceCandidates:[VoiceCandidate]=[]
    private(set) var speakerID:String?
    private(set) var speakerChangeFailed=false
    private(set) var speakerTalkTime:Int64=0
    private(set) var speakerQuote:String?
    private(set) var speakerSampleRange:Range<Int64>?
    private(set) var speakerPreparing=false
    @ObservationIgnored private var speakerPreparation:Task<Void,Never>?
    @ObservationIgnored private var speakerPreparationID=UUID()
    @ObservationIgnored private var speakerRetry:SpeakerEdits.Edit?
    var selectedSpeaker:MeetingSpeaker? { meeting?.speakers.first {$0.id==speakerID} }
    private(set) var meeting: LibraryMeeting?
    private(set) var working = false
    @ObservationIgnored private var task: Task<Void,Never>?
    @ObservationIgnored private var closing = false
    var normalized: String? { MeetingRename.normalized(name) }
    var canApply: Bool {
        guard let meeting else { return false }
        if presentation == .speakers {
            guard let speaker=selectedSpeaker else {return false}
            return canEditSpeakers(meeting) && SpeakerEdits.validName(name) && (SpeakerEdits.normalizedName(name) != speaker.name || voiceChoice.explicitlyDisabled || rememberVoice && SavedVoicesStore.validName(name) && voiceEnrollment != nil)
        }
        let original = meeting.title ?? UXText.text("library.untitled")
        return !working && name != original && (normalized == nil || normalized != original) && canRename(meeting)
    }
    func canRename(_ meeting: LibraryMeeting?) -> Bool {
        guard !closing, !working, !LibraryMoveCoordinator.shared.busy, !MeetingTrashCoordinator.shared.busy,
              let meeting, meeting.state.lifecycle == .saved, !meeting.metadataReadOnly,
              !LibraryStore.shared.context.screenshot, LibraryLocationModel.shared.available, !LibraryStore.shared.offline else { return false }
        if let detail = MeetingNavigation.shared.detail, detail.meeting.folder == meeting.folder, detail.fileURL != nil { return false }
        return LibraryLocationModel.shared.roots.contains { LibraryLocation.canonical($0) == LibraryLocation.canonical(meeting.folder.deletingLastPathComponent()) }
    }
    var commandMeeting: LibraryMeeting? {
        let search = LibrarySearchModel.shared
        if search.visible { return search.searching ? nil : search.selected.flatMap { search.meeting($0) } }
        return MeetingNavigation.shared.detail?.meeting ?? LibraryStore.shared.selected
    }
    var commandEnabled: Bool {
        guard NSApp.keyWindow?.accessibilityIdentifier() == "cassini-library-window", NSApp.keyWindow?.attachedSheet == nil else { return false }
        return canRename(commandMeeting)
    }
    func show(_ meeting: LibraryMeeting, presentation: Presentation = .sheet) {
        #if DEBUG
        if MeetingRenameFixture.enabled { NSLog("Hosted rename request: allowed=%d, current=%@, requested=%@",canRename(meeting),String(describing:self.presentation),String(describing:presentation)) }
        #endif
        guard canRename(meeting), self.presentation == nil else { return }
        stopSpeakerPreparation();speakerChangeFailed=false;speakerRetry=nil
        self.meeting = meeting; name = meeting.title ?? UXText.text("library.untitled"); self.presentation = presentation
    }
    func cancel() {
        stopSpeakerPreparation();MeetingNavigation.shared.detail?.speakerSample.cancel()
        presentation=nil;speakerChangeFailed=false;voiceChangeFailed=false;speakerRetry=nil
        if !working {meeting=nil;speakerID=nil}
    }
    func canEditSpeakers(_ meeting:LibraryMeeting?) -> Bool {
        guard canRename(meeting),let meeting,meeting.metadataRevision != nil else {return false}
        return ![.queued,.running].contains(meeting.state.transcript)
    }
    func showSpeaker(_ meeting:LibraryMeeting,id:String? = nil) {
        guard canEditSpeakers(meeting),presentation==nil,
              let speaker=id.flatMap({meeting.speaker(for:$0)}) ?? meeting.speakers.first else {return}
        presentSpeaker(meeting,speaker:speaker)
    }
    #if DEBUG
    /// Local bitmap evidence uses the sealed, read-only meeting fixture. All save
    /// and merge paths still pass canEditSpeakers, so preview cannot write it.
    func previewSpeaker(_ meeting:LibraryMeeting) async {
        guard LibraryStore.shared.context.screenshot,
              ProcessInfo.processInfo.environment["CASSINI_LOCAL_WORKFLOW_TESTS"] == "1",
              presentation == nil,
              let speaker=meeting.speakers.first(where: {$0.provenance == .unnamed}) ?? meeting.speakers.first else {return}
        presentSpeaker(meeting,speaker:speaker)
        await speakerPreparation?.value
    }
    #endif
    private func presentSpeaker(_ meeting:LibraryMeeting,speaker:MeetingSpeaker) {
        self.meeting=meeting;speakerID=speaker.id;name=speaker.name ?? ""
        if let detail=MeetingNavigation.shared.detail,detail.meeting.folder==meeting.folder {detail.namingSpeakerID=speaker.id}
        speakerChangeFailed=false;speakerRetry=nil;presentation = .speakers
        voiceChoice=SpeakerVoiceChoice(existing:SavedVoicesController.shared.snapshot?.voiceID(meeting:meeting.folder.lastPathComponent,speaker:speaker.id) != nil);voiceChangeFailed=false;voiceEnrollment=nil;voicePreparationFailed=false;savedVoiceID=nil;voiceCandidates=[]
        stopSpeakerPreparation();speakerPreparing=true;speakerSampleRange=nil;speakerQuote=nil
        let id=speaker.id, preparationID=UUID()
        speakerPreparationID=preparationID
        speakerPreparation=Task {
            defer { if speakerPreparationID == preparationID { speakerPreparation=nil } }
            let facts=await Task.detached(priority:.userInitiated) {
                (SpeakerEdits.talkTime(meeting,speaker:id),SpeakerEdits.sample(meeting,speaker:id),SpeakerEdits.quote(meeting,speaker:id))
            }.value
            guard !Task.isCancelled,!closing,presentation == .speakers,speakerID==id else {return}
            speakerTalkTime=facts.0;speakerSampleRange=facts.1;speakerQuote=facts.2;speakerPreparing=false
            await SavedVoicesController.shared.refresh()
            guard !Task.isCancelled, presentation == .speakers, speakerID == id else { return }
            if !voiceChoice.userChanged {
                let existing=SavedVoicesController.shared.snapshot?.voiceID(meeting:meeting.folder.lastPathComponent,speaker:id)
                voiceChoice=SpeakerVoiceChoice(existing:existing != nil)
                savedVoiceID=existing
            }
            do {
                let prepared=try await SavedVoicesController.shared.prepare(meeting,speaker:id)
                guard !Task.isCancelled, presentation == .speakers, speakerID == id else { return }
                voiceEnrollment=prepared
                let profiles=SavedVoicesController.shared.voices
                let ranked=await Task.detached(priority:.userInitiated) {
                    VoiceMatcher.ranked(prepared?.embedding ?? [],voices:profiles).map { VoiceCandidate(voice:$0.voice,score:$0.score) }
                }.value
                guard !Task.isCancelled, presentation == .speakers, speakerID == id else { return }
                voiceCandidates=ranked
            } catch { if !Task.isCancelled { voicePreparationFailed=true } }
        }
    }
    private func stopSpeakerPreparation() {speakerPreparation?.cancel();speakerPreparation=nil;speakerPreparing=false}
    func mergeSpeaker(_ meeting:LibraryMeeting,from id:String,into target:String) {
        guard canEditSpeakers(meeting),presentation==nil else {return}
        self.meeting=meeting;speakerID=id;performSpeakerEdit(.merge(from:id,into:target))
    }
    func mergeSpeaker(into id:String) {
        guard let speakerID else {return}
        performSpeakerEdit(.merge(from:speakerID,into:id))
    }
    func undoSpeakerMerge(_ meeting:LibraryMeeting) {
        guard canEditSpeakers(meeting),meeting.speakerMergeCount>0,presentation==nil else {return}
        self.meeting=meeting;performSpeakerEdit(.undoMerge)
    }
    var canRetrySpeakerEdit:Bool {
        guard canEditSpeakers(meeting),let edit=speakerRetry else {return false}
        if case .name = edit {return canApply}
        return true
    }
    func retrySpeakerEdit() {
        guard let edit=speakerRetry else {return}
        if case .name = edit {apply()} else {performSpeakerEdit(edit)}
    }
    func dismissSpeakerFailure() {speakerChangeFailed=false;voiceChangeFailed=false;speakerRetry=nil;if !working {meeting=nil}}
    private func performSpeakerEdit(_ edit:SpeakerEdits.Edit) {
        guard let meeting,canEditSpeakers(meeting) else {return}
        stopSpeakerPreparation();MeetingNavigation.shared.detail?.speakerSample.cancel()
        working=true;speakerChangeFailed=false;voiceChangeFailed=false;speakerRetry=edit
        let location=LibraryLocationModel.shared.location
        let scanner=LibraryStore.shared.scannerForRename(meeting) ?? LibraryScanner(root:meeting.folder.deletingLastPathComponent())
        let voiceUpdate=voiceChoice.update(prepared:voiceEnrollment != nil && SavedVoicesStore.validName(name))
        let enrollment=rememberVoice && SavedVoicesStore.validName(name) ? voiceEnrollment:nil, enrollmentName=name, voiceID=savedVoiceID
        task=Task {
            do {
                voiceChangeFailed=try await SpeakerEditTransaction.run(library: {
                    try await Task.detached(priority:.userInitiated) {
                        let access=try LibraryAccess(location,tolerateMissingPrevious:true)
                        defer {withExtendedLifetime(access) {}}
                        try SpeakerEdits.apply(edit,to:meeting,roots:access.roots,scanner:scanner)
                        return scanner.meeting(at:meeting.folder) ?? meeting
                    }.value
                }, committed: { updated in
                    self.speakerRetry=nil
                    if let detail=MeetingNavigation.shared.detail,detail.meeting.folder==meeting.folder,detail.fileURL==nil {detail.meeting=updated}
                    self.meeting=updated
                    LibraryStore.shared.refresh(affected:meeting.folder)
                }, readOnly: { try await SavedVoicesController.shared.store.snapshot().readOnly }, voices: {
                    switch edit {
                    case .merge(let from,let into):
                        try await SavedVoicesController.shared.store.unenroll(meeting:meeting.folder.lastPathComponent,speakers:[from,into])
                    case .undoMerge:
                        try await SavedVoicesController.shared.store.unenroll(meeting:meeting.folder.lastPathComponent,speakers:Set(meeting.mergedInto.keys).union(meeting.mergedInto.values))
                    case .name(let id,_):
                        if voiceUpdate == .forget {
                            try await SavedVoicesController.shared.store.unenroll(meeting:meeting.folder.lastPathComponent,speakers:[id])
                        } else if voiceUpdate == .enroll, let enrollment {
                            try await SavedVoicesController.shared.enroll(enrollment,name:enrollmentName,into:voiceID)
                        }
                    }
                    await SavedVoicesController.shared.refresh()
                })
                if !voiceChangeFailed { presentation=nil;self.meeting=nil;speakerID=nil }
            } catch {if !closing {speakerChangeFailed=true}}
            working=false;task=nil;LibraryMoveCoordinator.shared.maybeRetryDeferred()
        }
    }
    func apply() {
        guard canApply, let meeting else { return }
        if presentation == .speakers,let speakerID {
            performSpeakerEdit(.name(speaker:speakerID,value:name));return
        }
        working = true
        let name = self.name, location = LibraryLocationModel.shared.location
        let scanner = LibraryStore.shared.scannerForRename(meeting) ?? LibraryScanner(root:meeting.folder.deletingLastPathComponent())
        task = Task {
            do {
                let updated = try await Task.detached(priority:.userInitiated) {
                    let access = try LibraryAccess(location,tolerateMissingPrevious:true)
                    defer { withExtendedLifetime(access) {} }
                    guard access.roots.contains(where:{ LibraryLocation.canonical($0) == LibraryLocation.canonical(meeting.folder.deletingLastPathComponent()) }) else { throw POSIXError(.EACCES) }
                    try MeetingRename.apply(name,to:meeting)
                    guard let updated = try scanner.scan(affected:meeting.folder).meetings.first(where:{ $0.folder == meeting.folder }) else { throw POSIXError(.ENOENT) }
                    return updated
                }.value
                if let detail = MeetingNavigation.shared.detail, detail.meeting.folder == meeting.folder, detail.fileURL == nil {
                    detail.meeting.title = updated.title; detail.meeting.exportTitle = updated.exportTitle
                }
                LibraryStore.shared.refresh(affected:meeting.folder)
                presentation = nil; self.meeting = nil
            } catch { if !closing { NSApp.presentError(error) } }
            working = false; task = nil; LibraryMoveCoordinator.shared.maybeRetryDeferred()
        }
    }
    func dismissForQuit() async {
        stopSpeakerPreparation();MeetingNavigation.shared.detail?.speakerSample.cancel()
        let parent = NSApp.keyWindow?.sheetParent ?? NSApp.mainWindow
        presentation = nil
        for _ in 0..<40 {
            guard parent?.attachedSheet != nil else { return }; try? await Task.sleep(for:.milliseconds(25))
        }
    }
    func beginShutdown() { closing = true; stopSpeakerPreparation(); MeetingNavigation.shared.detail?.speakerSample.cancel(); presentation = nil }
    func waitForShutdown() async { await task?.value }
}
