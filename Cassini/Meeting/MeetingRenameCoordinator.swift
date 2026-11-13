// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import Observation
import CassiniLibrary

@MainActor @Observable final class MeetingRenameCoordinator {
    enum Presentation { case sheet, title, speakers }
    static let shared = MeetingRenameCoordinator()
    var presentation: Presentation?
    var name = ""
    private(set) var speakerID:String?
    private(set) var speakerChangeFailed=false
    private(set) var speakerTalkTime:Int64=0
    private(set) var speakerQuote: String?
    private(set) var speakerSampleRange:Range<Int64>?
    private(set) var speakerPreparing=false
    @ObservationIgnored private var speakerPreparation:Task<Void,Never>?
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
            return canEditSpeakers(meeting) && SpeakerEdits.validName(name) && SpeakerEdits.normalizedName(name) != speaker.name
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
        presentation=nil;speakerChangeFailed=false;speakerRetry=nil
        if !working {meeting=nil;speakerID=nil}
    }
    func canEditSpeakers(_ meeting:LibraryMeeting?) -> Bool {
        guard canRename(meeting),let meeting,meeting.metadataRevision != nil else {return false}
        return ![.queued,.running].contains(meeting.state.transcript)
    }
    func showSpeaker(_ meeting:LibraryMeeting,id:String? = nil) {
        guard canEditSpeakers(meeting),presentation==nil,
              let speaker=id.flatMap({meeting.speaker(for:$0)}) ?? meeting.speakers.first else {return}
        self.meeting=meeting;speakerID=speaker.id;name=speaker.name ?? ""
        if let detail=MeetingNavigation.shared.detail,detail.meeting.folder==meeting.folder {detail.namingSpeakerID=speaker.id}
        speakerChangeFailed=false;speakerRetry=nil;presentation = .speakers
        stopSpeakerPreparation();speakerPreparing=true;speakerSampleRange=nil;speakerQuote=nil
        let id=speaker.id
        speakerPreparation=Task {
            let facts=await Task.detached(priority:.userInitiated) {
                let sample = SpeakerEdits.sample(meeting, speaker: id)
                return (SpeakerEdits.talkTime(meeting, speaker: id), sample,
                        sample.flatMap { SpeakerEdits.sampleQuote(meeting, speaker: id, range: $0) })
            }.value
            guard !Task.isCancelled,!closing,presentation == .speakers,speakerID==id else {return}
            speakerTalkTime=facts.0;speakerSampleRange=facts.1;speakerQuote=facts.2;speakerPreparing=false;speakerPreparation=nil
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
    func dismissSpeakerFailure() {speakerChangeFailed=false;speakerRetry=nil;if !working {meeting=nil}}
    private func performSpeakerEdit(_ edit:SpeakerEdits.Edit) {
        guard let meeting,canEditSpeakers(meeting) else {return}
        stopSpeakerPreparation();MeetingNavigation.shared.detail?.speakerSample.cancel()
        working=true;speakerChangeFailed=false;speakerRetry=edit
        let location=LibraryLocationModel.shared.location
        let scanner=LibraryStore.shared.scannerForRename(meeting) ?? LibraryScanner(root:meeting.folder.deletingLastPathComponent())
        task=Task {
            do {
                let updated=try await Task.detached(priority:.userInitiated) {
                    let access=try LibraryAccess(location,tolerateMissingPrevious:true)
                    defer {withExtendedLifetime(access) {}}
                    try SpeakerEdits.apply(edit,to:meeting,roots:access.roots,scanner:scanner)
                    guard let updated=scanner.meeting(at:meeting.folder) else {throw POSIXError(.ENOENT)}
                    return updated
                }.value
                if let detail=MeetingNavigation.shared.detail,detail.meeting.folder==meeting.folder,detail.fileURL==nil {detail.meeting=updated}
                LibraryStore.shared.refresh(affected:meeting.folder)
                presentation=nil;self.meeting=nil;speakerID=nil;speakerRetry=nil
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
