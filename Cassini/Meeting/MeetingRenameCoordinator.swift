// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import Observation
import CassiniLibrary

@MainActor @Observable final class MeetingRenameCoordinator {
    enum Presentation { case sheet, title, speakers }
    static let shared = MeetingRenameCoordinator()
    var presentation: Presentation?

    private var titleName = ""
    struct VoiceCandidate: Identifiable, Sendable { let voice: SavedVoice; let score: Float?; var id: String { voice.id } }
    struct SpeakerDraft {
        var name: String
        var background: Bool
        var voiceChoice: SpeakerVoiceChoice
        var savedVoiceID: String?
        var voiceEnrollment: SavedVoicesController.TranscriptEnrollment?
        var voiceCandidates: [VoiceCandidate] = []
        var voicePreparationFailed = false
        var talkTime: Int64 = 0
        var quote: String?
        var sampleRange: Range<Int64>?
        var prepared = false
    }
    struct UndoToast: Identifiable {
        let id = UUID()
        let meeting: LibraryMeeting
        let message: String
        let snapshot: SpeakerEdits.BatchSnapshot
        let voiceBackups: [SavedVoicesStore.ContributionBackup]
    }

    private(set) var speakerDrafts: [String: SpeakerDraft] = [:]
    private(set) var speakerID: String?
    private(set) var speakerEditToast: UndoToast?
    @ObservationIgnored private var toastDismissTask: Task<Void, Never>?

    var name: String {
        get {
            if presentation == .speakers, let id = speakerID, let draft = speakerDrafts[id] {
                return draft.name
            }
            return titleName
        }
        set {
            if presentation == .speakers, let id = speakerID {
                speakerDrafts[id]?.name = newValue
            } else {
                titleName = newValue
            }
        }
    }

    var isBackgroundVoice: Bool {
        get { speakerID.flatMap { speakerDrafts[$0]?.background } ?? false }
        set {
            guard let id = speakerID else { return }
            speakerDrafts[id]?.background = newValue
        }
    }

    var rememberVoice: Bool {
        get { speakerID.flatMap { speakerDrafts[$0]?.voiceChoice.remember } ?? false }
        set {
            guard let id = speakerID else { return }
            speakerDrafts[id]?.voiceChoice.choose(newValue)
        }
    }

    var savedVoiceID: String? {
        get { speakerID.flatMap { speakerDrafts[$0]?.savedVoiceID } }
        set {
            guard let id = speakerID else { return }
            speakerDrafts[id]?.savedVoiceID = newValue
        }
    }

    var voiceEnrollment: SavedVoicesController.TranscriptEnrollment? {
        speakerID.flatMap { speakerDrafts[$0]?.voiceEnrollment }
    }
    var voicePreparationFailed: Bool {
        speakerID.flatMap { speakerDrafts[$0]?.voicePreparationFailed } ?? false
    }
    var voiceCandidates: [VoiceCandidate] {
        speakerID.flatMap { speakerDrafts[$0]?.voiceCandidates } ?? []
    }
    var speakerTalkTime: Int64 {
        speakerID.flatMap { speakerDrafts[$0]?.talkTime } ?? 0
    }
    var speakerQuote: String? {
        speakerID.flatMap { speakerDrafts[$0]?.quote }
    }
    var speakerSampleRange: Range<Int64>? {
        speakerID.flatMap { speakerDrafts[$0]?.sampleRange }
    }
    private(set) var speakerPreparing = false
    private(set) var voiceChangeFailed = false
    private(set) var speakerChangeFailed = false

    var canChangeRememberVoice: Bool {
        guard !working, !isBackgroundVoice, !SavedVoicesController.shared.readOnly else { return false }
        return voiceEnrollment != nil || meeting.flatMap { meeting in
            speakerID.flatMap { SavedVoicesController.shared.snapshot?.voiceID(meeting: meeting.folder.lastPathComponent, speaker: $0) }
        } != nil
    }

    @ObservationIgnored private var speakerPreparation: Task<Void, Never>?
    @ObservationIgnored private var speakerPreparationID = UUID()
    @ObservationIgnored private var speakerRetry: SpeakerEdits.Edit?

    var selectedSpeaker: MeetingSpeaker? { meeting?.speakers.first { $0.id == speakerID } }
    private(set) var meeting: LibraryMeeting?
    private(set) var working = false
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var closing = false

    var normalized: String? { MeetingRename.normalized(name) }

    func draftIsBackground(for id: String) -> Bool {
        speakerDrafts[id]?.background ?? meeting?.speaker(for: id)?.background ?? false
    }

    func draftDisplayName(for speaker: MeetingSpeaker) -> String {
        if let draft = speakerDrafts[speaker.id], !draft.background,
           let typed = SpeakerEdits.normalizedName(draft.name) {
            return typed
        }
        return speaker.displayName(language: UXText.language, locale: UXText.locale)
    }

    private func speakerHasPendingChange(_ speaker: MeetingSpeaker, draft: SpeakerDraft) -> Bool {
        if draft.background != speaker.background { return true }
        if !draft.background {
            if SpeakerEdits.normalizedName(draft.name) != speaker.name { return true }
            if draft.voiceChoice.explicitlyDisabled { return true }
            if draft.voiceChoice.remember && SavedVoicesStore.validName(draft.name) && draft.voiceEnrollment != nil { return true }
        }
        return false
    }

    var canApply: Bool {
        guard let meeting else { return false }
        if presentation == .speakers {
            guard canEditSpeakers(meeting) else { return false }
            var anyChange = false
            for speaker in meeting.speakers {
                guard let draft = speakerDrafts[speaker.id] else { continue }
                if !draft.background && !SpeakerEdits.validName(draft.name) { return false }
                if speakerHasPendingChange(speaker, draft: draft) { anyChange = true }
            }
            return anyChange
        }
        let original = meeting.title ?? UXText.text("library.untitled")
        return !working && titleName != original && (normalized == nil || normalized != original) && canRename(meeting)
    }

    func canRename(_ meeting: LibraryMeeting?) -> Bool {
        guard !closing, !working, !LibraryMoveCoordinator.shared.busy, !MeetingTrashCoordinator.shared.busy,
              !MeetingDateTimeCoordinator.shared.working,
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
        if MeetingRenameFixture.enabled { NSLog("Hosted rename request: allowed=%d, current=%@, requested=%@", canRename(meeting), String(describing: self.presentation), String(describing: presentation)) }
        #endif
        guard canRename(meeting), self.presentation == nil else { return }
        stopSpeakerPreparation(); speakerChangeFailed = false; voiceChangeFailed = false; speakerRetry = nil
        self.meeting = meeting; titleName = meeting.title ?? UXText.text("library.untitled"); self.presentation = presentation
    }

    func cancel() {
        stopSpeakerPreparation(); MeetingNavigation.shared.detail?.speakerSample.cancel()
        presentation = nil; speakerChangeFailed = false; voiceChangeFailed = false; speakerRetry = nil
        if !working { meeting = nil; speakerID = nil; speakerDrafts = [:] }
    }

    func canEditSpeakers(_ meeting: LibraryMeeting?) -> Bool {
        guard canRename(meeting), let meeting, meeting.metadataRevision != nil else { return false }
        return ![.queued, .running].contains(meeting.state.transcript)
    }

    func showSpeaker(_ meeting: LibraryMeeting, id: String? = nil) {
        guard canEditSpeakers(meeting), presentation == nil,
              let speaker = id.flatMap({ meeting.speaker(for: $0) }) ?? meeting.speakers.first else { return }
        presentSpeaker(meeting, speaker: speaker)
    }

    func selectSpeaker(_ id: String) {
        guard !working, presentation == .speakers, let meeting, id != speakerID,
              meeting.speakers.contains(where: { $0.id == id }) else { return }
        MeetingNavigation.shared.detail?.speakerSample.cancel()
        speakerID = id
        if let detail = MeetingNavigation.shared.detail, detail.meeting.folder == meeting.folder {
            detail.namingSpeakerID = id
        }
        if speakerDrafts[id]?.prepared == true {
            stopSpeakerPreparation()
        } else {
            prepareSpeaker(id, in: meeting)
        }
    }

    func canStepSpeaker(_ direction: Int) -> Bool {
        guard !working, presentation == .speakers, let meeting, let speakerID,
              let index = meeting.speakers.firstIndex(where: { $0.id == speakerID }) else { return false }
        return meeting.speakers.indices.contains(index + direction)
    }

    func stepSpeaker(_ direction: Int) {
        guard canStepSpeaker(direction), let meeting, let speakerID,
              let index = meeting.speakers.firstIndex(where: { $0.id == speakerID }) else { return }
        selectSpeaker(meeting.speakers[index + direction].id)
    }

    #if DEBUG
    /// Local bitmap evidence uses the sealed, read-only meeting fixture. All save
    /// and merge paths still pass canEditSpeakers, so preview cannot write it.
    func previewSpeaker(_ meeting: LibraryMeeting, id: String? = nil, markBackground: Bool = false) async {
        guard LibraryStore.shared.context.screenshot,
              ProcessInfo.processInfo.environment["CASSINI_LOCAL_WORKFLOW_TESTS"] == "1",
              presentation == nil,
              let speaker = id.flatMap({ meeting.speaker(for: $0) }) ?? meeting.speakers.first(where: { $0.provenance == .unnamed }) ?? meeting.speakers.first else { return }
        presentSpeaker(meeting, speaker: speaker)
        await speakerPreparation?.value
        if markBackground { isBackgroundVoice = true }
    }
    func previewToast(message: String, meeting: LibraryMeeting) {
        guard LibraryStore.shared.context.screenshot else { return }
        speakerEditToast = UndoToast(meeting: meeting, message: message, snapshot: .init(entries: [:]), voiceBackups: [])
    }
    #endif

    private func presentSpeaker(_ meeting: LibraryMeeting, speaker: MeetingSpeaker) {
        self.meeting = meeting
        speakerID = speaker.id
        var drafts: [String: SpeakerDraft] = [:]
        for item in meeting.speakers {
            let existingVoice = SavedVoicesController.shared.snapshot?.voiceID(meeting: meeting.folder.lastPathComponent, speaker: item.id)
            drafts[item.id] = SpeakerDraft(
                name: item.name ?? "",
                background: item.background,
                voiceChoice: VoicePreferences.shared.choice(existing: existingVoice != nil),
                savedVoiceID: existingVoice
            )
        }
        speakerDrafts = drafts
        if let detail = MeetingNavigation.shared.detail, detail.meeting.folder == meeting.folder {
            detail.namingSpeakerID = speaker.id
        }
        speakerChangeFailed = false; voiceChangeFailed = false; speakerRetry = nil; presentation = .speakers
        prepareSpeaker(speaker.id, in: meeting)
    }

    private func prepareSpeaker(_ id: String, in meeting: LibraryMeeting) {
        stopSpeakerPreparation(); speakerPreparing = true
        let preparationID = UUID()
        speakerPreparationID = preparationID
        speakerPreparation = Task {
            defer { if speakerPreparationID == preparationID { speakerPreparation = nil } }
            let facts = await Task.detached(priority: .userInitiated) {
                (SpeakerEdits.talkTime(meeting, speaker: id), SpeakerEdits.sample(meeting, speaker: id), SpeakerEdits.quote(meeting, speaker: id))
            }.value
            guard !Task.isCancelled, !closing, presentation == .speakers, speakerID == id else { return }
            speakerDrafts[id]?.talkTime = facts.0
            speakerDrafts[id]?.sampleRange = facts.1
            speakerDrafts[id]?.quote = facts.2
            speakerDrafts[id]?.prepared = true
            speakerPreparing = false
            await SavedVoicesController.shared.refresh()
            guard !Task.isCancelled, presentation == .speakers, speakerID == id else { return }
            if speakerDrafts[id]?.voiceChoice.userChanged == false {
                let existing = SavedVoicesController.shared.snapshot?.voiceID(meeting: meeting.folder.lastPathComponent, speaker: id)
                speakerDrafts[id]?.voiceChoice = VoicePreferences.shared.choice(existing: existing != nil)
                speakerDrafts[id]?.savedVoiceID = existing
            }
            do {
                let prepared = try await SavedVoicesController.shared.prepare(meeting, speaker: id)
                guard !Task.isCancelled, presentation == .speakers, speakerID == id else { return }
                speakerDrafts[id]?.voiceEnrollment = prepared
                let profiles = SavedVoicesController.shared.voices
                let ranked = await Task.detached(priority: .userInitiated) {
                    VoiceMatcher.ranked(prepared?.embedding ?? [], voices: profiles).map { VoiceCandidate(voice: $0.voice, score: $0.score) }
                }.value
                guard !Task.isCancelled, presentation == .speakers, speakerID == id else { return }
                speakerDrafts[id]?.voiceCandidates = ranked
            } catch {
                if !Task.isCancelled { speakerDrafts[id]?.voicePreparationFailed = true }
            }
        }
    }

    private func stopSpeakerPreparation() { speakerPreparation?.cancel(); speakerPreparation = nil; speakerPreparing = false }

    func mergeSpeaker(_ meeting: LibraryMeeting, from id: String, into target: String) {
        guard canEditSpeakers(meeting), presentation == nil else { return }
        self.meeting = meeting; speakerID = id; performSpeakerEdit(.merge(from: id, into: target))
    }

    func mergeSpeaker(into id: String) {
        guard let speakerID else { return }
        performSpeakerEdit(.merge(from: speakerID, into: id))
    }

    func undoSpeakerMerge(_ meeting: LibraryMeeting) {
        guard canEditSpeakers(meeting), meeting.speakerMergeCount > 0, presentation == nil else { return }
        self.meeting = meeting; performSpeakerEdit(.undoMerge)
    }

    var canRetrySpeakerEdit: Bool {
        guard canEditSpeakers(meeting), let edit = speakerRetry else { return false }
        if case .name = edit { return canApply }
        if case .batch = edit { return canApply }
        return true
    }

    func retrySpeakerEdit() {
        guard let edit = speakerRetry else { return }
        if case .name = edit { apply() }
        else if case .batch = edit { apply() }
        else { performSpeakerEdit(edit) }
    }

    func dismissSpeakerFailure() { speakerChangeFailed = false; voiceChangeFailed = false; speakerRetry = nil; if !working { meeting = nil } }

    func dismissToast() {
        toastDismissTask?.cancel(); toastDismissTask = nil
        speakerEditToast = nil
    }

    private func showToast(_ toast: UndoToast) {
        toastDismissTask?.cancel()
        speakerEditToast = toast
        toastDismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled, let self, self.speakerEditToast?.id == toast.id else { return }
            self.speakerEditToast = nil
        }
    }

    func undoLastSpeakerEdit() {
        guard let toast = speakerEditToast, canEditSpeakers(toast.meeting) else { return }
        dismissToast()
        let meeting = toast.meeting
        let snapshot = toast.snapshot
        let voiceBackups = toast.voiceBackups
        working = true; speakerChangeFailed = false; voiceChangeFailed = false
        let location = LibraryLocationModel.shared.location
        let scanner = LibraryStore.shared.scannerForRename(meeting) ?? LibraryScanner(root: meeting.folder.deletingLastPathComponent())
        task = Task {
            do {
                voiceChangeFailed = try await SpeakerEditTransaction.run(changesVoices: !voiceBackups.isEmpty, library: {
                    try await Task.detached(priority: .userInitiated) {
                        let access = try LibraryAccess(location, tolerateMissingPrevious: true)
                        defer { withExtendedLifetime(access) {} }
                        try SpeakerEdits.apply(.restore(snapshot), to: meeting, roots: access.roots, scanner: scanner)
                        return scanner.meeting(at: meeting.folder) ?? meeting
                    }.value
                }, committed: { updated in
                    if let detail = MeetingNavigation.shared.detail, detail.meeting.folder == meeting.folder, detail.fileURL == nil {
                        detail.meeting = updated
                    }
                    LibraryStore.shared.refresh(affected: meeting.folder)
                }, readOnly: { try await SavedVoicesController.shared.store.snapshot().readOnly }, voices: {
                    if !voiceBackups.isEmpty {
                        try await SavedVoicesController.shared.store.restore(voiceBackups)
                        await SavedVoicesController.shared.refresh()
                    }
                })
            } catch {
                if !closing { speakerChangeFailed = true }
            }
            working = false; task = nil; LibraryMoveCoordinator.shared.maybeRetryDeferred()
        }
    }

    /// Formats the post-Save summary toast message per D112 (L-86) catalog strings.
    static func toastMessage(named: [String], newlyBackground: [String], unbackgroundedCount: Int,
                             locale: Locale = UXText.locale, language: CassiniLanguage = UXText.language) -> String? {
        guard !newlyBackground.isEmpty else { return nil }
        if !named.isEmpty {
            let namesList = LibraryFormat(locale: locale, language: language).list(named)
            return LibraryLocalization.shared.text("speakers.backgroundVoice.toast.namedAndBackground",
                                                   ["name": namesList, "n": String(newlyBackground.count)],
                                                   language: language, locale: locale)
        }
        if newlyBackground.count == 1 && unbackgroundedCount == 0 {
            return LibraryLocalization.shared.text("speakers.backgroundVoice.toast.single",
                                                   ["name": newlyBackground[0]],
                                                   language: language, locale: locale)
        }
        return LibraryLocalization.shared.text("speakers.backgroundVoice.toast.count",
                                               ["n": String(newlyBackground.count)],
                                               language: language, locale: locale)
    }

    private func performBatchSpeakerSave() {
        guard let meeting, canEditSpeakers(meeting) else { return }
        var changes: [SpeakerEdits.BatchChange] = []
        var toForget: Set<String> = []
        var toEnroll: [(id: String, enrollment: SavedVoicesController.TranscriptEnrollment, name: String, voiceID: String?)] = []
        var namedNames: [String] = []
        var newlyBackgroundNames: [String] = []
        var unbackgroundedCount = 0

        for speaker in meeting.speakers {
            guard let draft = speakerDrafts[speaker.id] else { continue }
            let bgChanged = draft.background != speaker.background
            let normalizedNew = SpeakerEdits.normalizedName(draft.name)
            let nameChanged = !draft.background && normalizedNew != speaker.name
            if bgChanged || nameChanged {
                changes.append(.init(
                    speaker: speaker.id,
                    name: nameChanged ? draft.name : nil,
                    background: bgChanged ? draft.background : nil
                ))
            }
            if bgChanged {
                if draft.background {
                    newlyBackgroundNames.append(speaker.displayName(language: UXText.language, locale: UXText.locale))
                } else {
                    unbackgroundedCount += 1
                }
            }
            if nameChanged, let newName = normalizedNew {
                namedNames.append(newName)
            }
            // D112 (L-86): no voiceprint is enrolled while Background voice is on.
            if !draft.background {
                let voiceUpdate = draft.voiceChoice.update(prepared: draft.voiceEnrollment != nil && SavedVoicesStore.validName(draft.name))
                if voiceUpdate == .forget {
                    toForget.insert(speaker.id)
                } else if voiceUpdate == .enroll, let enrollment = draft.voiceEnrollment {
                    toEnroll.append((speaker.id, enrollment, draft.name, draft.savedVoiceID))
                }
            }
        }

        let edit: SpeakerEdits.Edit = .batch(changes)
        let changesVoices = !toForget.isEmpty || !toEnroll.isEmpty
        let summaryMessage = Self.toastMessage(named: namedNames, newlyBackground: newlyBackgroundNames, unbackgroundedCount: unbackgroundedCount)

        stopSpeakerPreparation(); MeetingNavigation.shared.detail?.speakerSample.cancel()
        working = true; speakerChangeFailed = false; voiceChangeFailed = false; speakerRetry = edit
        let location = LibraryLocationModel.shared.location
        let scanner = LibraryStore.shared.scannerForRename(meeting) ?? LibraryScanner(root: meeting.folder.deletingLastPathComponent())

        task = Task {
            do {
                var capturedSnapshot: SpeakerEdits.BatchSnapshot?
                var committedVoiceBackups: [SavedVoicesStore.ContributionBackup] = []
                voiceChangeFailed = try await SpeakerEditTransaction.run(changesVoices: changesVoices, library: {
                    try await Task.detached(priority: .userInitiated) {
                        let access = try LibraryAccess(location, tolerateMissingPrevious: true)
                        defer { withExtendedLifetime(access) {} }
                        let snap = try SpeakerEdits.applyReturningSnapshot(edit, to: meeting, roots: access.roots, scanner: scanner)
                        return (scanner.meeting(at: meeting.folder) ?? meeting, snap)
                    }.value
                }, committed: { result in
                    let (updated, snap) = result
                    capturedSnapshot = snap
                    self.speakerRetry = nil
                    if let detail = MeetingNavigation.shared.detail, detail.meeting.folder == meeting.folder, detail.fileURL == nil {
                        detail.meeting = updated
                    }
                    self.meeting = updated
                    LibraryStore.shared.refresh(affected: meeting.folder)
                }, readOnly: { try await SavedVoicesController.shared.store.snapshot().readOnly }, voices: {
                    do {
                        if !toForget.isEmpty {
                            let backups = try await SavedVoicesController.shared.store.unenrollReturningBackups(meeting: meeting.folder.lastPathComponent, speakers: toForget)
                            committedVoiceBackups.append(contentsOf: backups)
                        }
                        for item in toEnroll {
                            if let backup = try await SavedVoicesController.shared.enroll(item.enrollment, name: item.name, into: item.voiceID) {
                                committedVoiceBackups.append(backup)
                            }
                        }
                        await SavedVoicesController.shared.refresh()
                    } catch {
                        if !committedVoiceBackups.isEmpty {
                            await SavedVoicesController.shared.refresh()
                        }
                        throw error
                    }
                })
                let updatedMeeting = self.meeting ?? meeting
                presentation = nil; self.meeting = nil; speakerID = nil; speakerDrafts = [:]
                if let summaryMessage, let capturedSnapshot {
                    showToast(UndoToast(meeting: updatedMeeting, message: summaryMessage, snapshot: capturedSnapshot, voiceBackups: committedVoiceBackups))
                }
            } catch {
                if !closing { speakerChangeFailed = true }
            }
            working = false; task = nil; LibraryMoveCoordinator.shared.maybeRetryDeferred()
        }
    }

    private func performSpeakerEdit(_ edit: SpeakerEdits.Edit) {
        guard let meeting, canEditSpeakers(meeting) else { return }
        stopSpeakerPreparation(); MeetingNavigation.shared.detail?.speakerSample.cancel()
        working = true; speakerChangeFailed = false; voiceChangeFailed = false; speakerRetry = edit
        let location = LibraryLocationModel.shared.location
        let scanner = LibraryStore.shared.scannerForRename(meeting) ?? LibraryScanner(root: meeting.folder.deletingLastPathComponent())
        task = Task {
            do {
                voiceChangeFailed = try await SpeakerEditTransaction.run(changesVoices: true, library: {
                    try await Task.detached(priority: .userInitiated) {
                        let access = try LibraryAccess(location, tolerateMissingPrevious: true)
                        defer { withExtendedLifetime(access) {} }
                        try SpeakerEdits.apply(edit, to: meeting, roots: access.roots, scanner: scanner)
                        return scanner.meeting(at: meeting.folder) ?? meeting
                    }.value
                }, committed: { updated in
                    self.speakerRetry = nil
                    if let detail = MeetingNavigation.shared.detail, detail.meeting.folder == meeting.folder, detail.fileURL == nil { detail.meeting = updated }
                    self.meeting = updated
                    LibraryStore.shared.refresh(affected: meeting.folder)
                }, readOnly: { try await SavedVoicesController.shared.store.snapshot().readOnly }, voices: {
                    switch edit {
                    case .merge(let from, let into):
                        try await SavedVoicesController.shared.store.unenroll(meeting: meeting.folder.lastPathComponent, speakers: [from, into])
                    case .undoMerge:
                        try await SavedVoicesController.shared.store.unenroll(meeting: meeting.folder.lastPathComponent, speakers: Set(meeting.mergedInto.keys).union(meeting.mergedInto.values))
                    default: break
                    }
                    await SavedVoicesController.shared.refresh()
                })
                presentation = nil; self.meeting = nil; speakerID = nil; speakerDrafts = [:]
            } catch { if !closing { speakerChangeFailed = true } }
            working = false; task = nil; LibraryMoveCoordinator.shared.maybeRetryDeferred()
        }
    }

    func renameInline(_ meeting: LibraryMeeting, to newTitle: String) {
        let original = meeting.title ?? UXText.text("library.untitled")
        guard canRename(meeting), newTitle != original else { return }
        let normalizedNew = MeetingRename.normalized(newTitle)
        guard normalizedNew == nil || normalizedNew != original else { return }
        self.meeting = meeting
        self.titleName = newTitle
        apply()
    }

    func apply() {
        guard canApply, let meeting else { return }
        if presentation == .speakers {
            performBatchSpeakerSave(); return
        }
        working = true
        let name = self.titleName, location = LibraryLocationModel.shared.location
        let scanner = LibraryStore.shared.scannerForRename(meeting) ?? LibraryScanner(root: meeting.folder.deletingLastPathComponent())
        task = Task {
            do {
                let updated = try await Task.detached(priority: .userInitiated) {
                    let access = try LibraryAccess(location, tolerateMissingPrevious: true)
                    defer { withExtendedLifetime(access) {} }
                    guard access.roots.contains(where: { LibraryLocation.canonical($0) == LibraryLocation.canonical(meeting.folder.deletingLastPathComponent()) }) else { throw POSIXError(.EACCES) }
                    try MeetingRename.apply(name, to: meeting)
                    guard let updated = try scanner.scan(affected: meeting.folder).meetings.first(where: { $0.folder == meeting.folder }) else { throw POSIXError(.ENOENT) }
                    return updated
                }.value
                if let detail = MeetingNavigation.shared.detail, detail.meeting.folder == meeting.folder, detail.fileURL == nil {
                    detail.meeting.title = updated.title; detail.meeting.exportTitle = updated.exportTitle
                }
                LibraryStore.shared.refresh(affected: meeting.folder)
                presentation = nil; self.meeting = nil
            } catch { if !closing { NSApp.presentError(error) } }
            working = false; task = nil; LibraryMoveCoordinator.shared.maybeRetryDeferred()
        }
    }

    func dismissForQuit() async {
        stopSpeakerPreparation(); MeetingNavigation.shared.detail?.speakerSample.cancel()
        let parent = NSApp.keyWindow?.sheetParent ?? NSApp.mainWindow
        presentation = nil
        for _ in 0..<40 {
            guard parent?.attachedSheet != nil else { return }; try? await Task.sleep(for: .milliseconds(25))
        }
    }

    func beginShutdown() { closing = true; stopSpeakerPreparation(); toastDismissTask?.cancel(); MeetingNavigation.shared.detail?.speakerSample.cancel(); presentation = nil }
    func waitForShutdown() async { await task?.value }
}
