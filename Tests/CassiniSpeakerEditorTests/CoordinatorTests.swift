// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
import Observation
import CassiniLibrary
import CassiniRecording

@MainActor @Suite(.serialized) struct CoordinatorTests {
    nonisolated private static func makeFixture() throws -> (URL,LibraryMeeting) {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("SpeakerCoordinator-"+UUID().uuidString)
        let session=try RecordingSession(parent:root,title:"Call",source:"macos")
        try session.addTrack(id:"mic",label:"Mic",kind:"microphone",sampleRate:16000,channels:1)
        try session.append(id:"mic",pcm:Data(repeating:1,count:32000),offsetMs:0)
        try session.finish()
        try MeetingMetadataWriter(directory:session.directory,id:session.manifest.id).transaction {
            $0["transcript"]=["status":"done","reference":["kind":"sidecar","file":"transcript.json","format":"cassini.words.v1"]]
            $0["speakers"]=[["id":"a","name":"Alice","provenance":"user","colourIndex":0],
                             ["id":"b","name":"Bob","provenance":"user","colourIndex":1]]
        }
        try Data("{\"language\":\"en\",\"items\":[{\"speaker\":\"a\",\"startMs\":0,\"endMs\":500,\"text\":\"Hello\"},{\"speaker\":\"b\",\"startMs\":500,\"endMs\":900,\"text\":\"Hi\"}]}".utf8).write(to:session.directory.appendingPathComponent("transcript.json"))
        // A regular file cannot be a voice-store directory, independent of UID or chmod.
        let broken=root.appendingPathComponent("broken-voices")
        try Data("broken".utf8).write(to:broken)
        return (root,try #require(LibraryScanner(root:root).meeting(at:session.directory)))
    }
    private func fixture() async throws -> (URL,LibraryMeeting) {
        let (root,meeting)=try await Task.detached { try Self.makeFixture() }.value
        SavedVoicesController.shared.store=SavedVoicesStore(directory:root.appendingPathComponent("broken-voices"))
        LibraryLocationModel.shared.location=LibraryLocation(primary:root)
        return (root,meeting)
    }
    @Test func dialogMergeClosesAfterVoiceFailureAndNextShowClearsFailure() async throws {
        let (root,meeting)=try await fixture()
        defer {try? FileManager.default.removeItem(at:root)}
        let coordinator=MeetingRenameCoordinator()
        coordinator.showSpeaker(meeting,id:"a")
        #expect(coordinator.presentation == .speakers)
        coordinator.mergeSpeaker(into:"b")
        await coordinator.waitForShutdown()
        #expect(coordinator.presentation == nil)
        #expect(coordinator.meeting == nil)
        #expect(coordinator.speakerID == nil)
        #expect(coordinator.voiceChangeFailed)
        #expect(!coordinator.speakerChangeFailed && !coordinator.canRetrySpeakerEdit)
        let updated=try #require(LibraryScanner(root:root).meeting(at:meeting.folder))
        #expect(!updated.speakers.contains { $0.id == "a" })
        #expect(updated.speakerMergeCount == 1)
        coordinator.show(updated,presentation:.sheet)
        #expect(coordinator.presentation == .sheet)
        #expect(!coordinator.voiceChangeFailed)
        coordinator.cancel()
    }
    @Test func namePreservingVoiceSucceedsWithBrokenStore() async throws {
        let (root,meeting)=try await fixture()
        defer {try? FileManager.default.removeItem(at:root)}
        let coordinator=MeetingRenameCoordinator()
        coordinator.showSpeaker(meeting,id:"a")
        coordinator.name="Alice corrected"
        #expect(coordinator.canApply)
        coordinator.apply()
        await coordinator.waitForShutdown()
        #expect(coordinator.presentation == nil && coordinator.meeting == nil && coordinator.speakerID == nil)
        #expect(!coordinator.voiceChangeFailed && !coordinator.speakerChangeFailed)
        #expect(LibraryScanner(root:root).meeting(at:meeting.folder)?.speaker(for:"a")?.name == "Alice corrected")
    }

    // The real coordinator suspends at refresh while the test chooses what the
    // newly loaded snapshot contains. No clock delay determines the ordering.
    @MainActor private final class RefreshGate {
        let (entered, didEnter)=AsyncStream<Void>.makeStream()
        let (released, release)=AsyncStream<Void>.makeStream()
        func pause() async {
            didEnter.yield(());didEnter.finish()
            for await _ in released { break }
        }
        func waitUntilEntered() async { for await _ in entered { break } }
        func resume() {release.yield(());release.finish()}
    }
    private func waitForEnrollment(_ coordinator:MeetingRenameCoordinator) async {
        while coordinator.voiceEnrollment == nil {
            let (events,emit)=AsyncStream<Void>.makeStream()
            let ready=withObservationTracking {coordinator.voiceEnrollment != nil} onChange: {
                emit.yield(());emit.finish()
            }
            if ready {emit.finish();return}
            for await _ in events {break}
        }
    }
    private func checkVoiceChoice(enabled:Bool,existingBefore:Bool=false,existingAfter:Bool=false,userChoice:Bool?=nil) async throws {
        let (root,meeting)=try await fixture()
        do {
            try await checkVoiceChoice(meeting:meeting,root:root,enabled:enabled,existingBefore:existingBefore,existingAfter:existingAfter,userChoice:userChoice)
        } catch {
            await Task.detached {try? FileManager.default.removeItem(at:root)}.value
            throw error
        }
        await Task.detached {try? FileManager.default.removeItem(at:root)}.value
    }
    private func checkVoiceChoice(meeting:LibraryMeeting,root:URL,enabled:Bool,existingBefore:Bool,existingAfter:Bool,userChoice:Bool?) async throws {
        let suite="io.codemyriad.cassini.speaker-choice."+UUID().uuidString
        let defaults=UserDefaults(suiteName:suite)!
        let previous=VoicePreferences.shared
        VoicePreferences.shared=VoicePreferences(defaults:defaults)
        VoicePreferences.shared.remember=enabled
        let voices=SavedVoicesController.shared,coordinator=MeetingRenameCoordinator(),gate=RefreshGate()
        defer {
            gate.resume();coordinator.cancel()
            voices.refreshAction=nil;voices.prepared=nil;voices.snapshot=nil
            VoicePreferences.shared=previous;defaults.removePersistentDomain(forName:suite)
        }
        let store=SavedVoicesStore(directory:root.appendingPathComponent("voices"))
        voices.store=store
        let empty=try await store.snapshot()
        let voiceID=try await store.enroll(name:"Alice",embedding:[Float](repeating:1,count:512),seconds:5,generation:empty.generation,
            clip:.init(meeting:meeting.folder.lastPathComponent,speaker:"a",startMs:0,endMs:5000))
        let saved=try await store.snapshot()
        voices.snapshot=existingBefore ? saved:empty
        voices.prepared = .init(embedding:[Float](repeating:1,count:512))
        voices.refreshAction = {
            await gate.pause()
            voices.snapshot=existingAfter ? saved:empty
        }
        coordinator.showSpeaker(meeting,id:"a")
        #expect(coordinator.presentation == .speakers)
        #expect(coordinator.rememberVoice == (enabled || existingBefore),"Initial speaker-editor default")
        await gate.waitUntilEntered()
        if let userChoice {coordinator.rememberVoice=userChoice}
        gate.resume()
        await waitForEnrollment(coordinator)
        #expect(coordinator.rememberVoice == (userChoice ?? (enabled || existingAfter)),"Refresh must use the preference and preserve an explicit choice")
        if userChoice == nil {#expect(coordinator.savedVoiceID == (existingAfter ? voiceID:nil))}
        // Preparing an editor never enrolls another contribution.
        #expect(try await store.snapshot().voices.first?.count == 1)
    }
    @Test(.timeLimit(.minutes(1)),arguments:[false,true])
    func preferenceDrivesBothSpeakerPreparationPaths(_ enabled:Bool) async throws {
        try await checkVoiceChoice(enabled:enabled)
    }
    @Test(.timeLimit(.minutes(1)),arguments:[false,true])
    func existingVoiceSurvivesDisabledDefault(_ cached:Bool) async throws {
        try await checkVoiceChoice(enabled:false,existingBefore:cached,existingAfter:true)
    }
    @Test(.timeLimit(.minutes(1)),arguments:[false,true])
    func explicitChoiceSurvivesPendingVoiceRefresh(_ choice:Bool) async throws {
        try await checkVoiceChoice(enabled:!choice,existingAfter:true,userChoice:choice)
    }

    @Test func renameInlineNormalizesWhitespaceAndResetsOnBlank() async throws {
        let (root,_)=try await fixture()
        defer {try? FileManager.default.removeItem(at:root)}
        let meeting=try #require(LibraryScanner(root:root).scan().meetings.first)
        let coordinator=MeetingRenameCoordinator()
        // Surrounding whitespace normalizes on commit.
        coordinator.renameInline(meeting,to:"  Board notes  ")
        await coordinator.waitForShutdown()
        let renamed=try #require(LibraryScanner(root:root).scan().meetings.first)
        #expect(renamed.title == "Board notes")
        // Equivalent whitespace-padded title is a no-op.
        coordinator.renameInline(renamed,to:"  Board notes ")
        await coordinator.waitForShutdown()
        #expect(try LibraryScanner(root:root).scan().meetings.first?.title == "Board notes")
        // Blank / whitespace-only restores the automatic title.
        coordinator.renameInline(renamed,to:"   ")
        await coordinator.waitForShutdown()
        let restored=try #require(LibraryScanner(root:root).scan().meetings.first)
        #expect(restored.title == "Call")
    }

    @Test func speakerRowBatchEditToastAndUndoWithSevenSpeakers() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SpeakerRowBatch-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try RecordingSession(parent: root, title: "Busy cafe", source: "macos")
        try session.addTrack(id: "mic", label: "Mic", kind: "microphone", sampleRate: 16000, channels: 1)
        try session.append(id: "mic", pcm: Data(repeating: 1, count: 32000), offsetMs: 0)
        try session.finish()
        try MeetingMetadataWriter(directory: session.directory, id: session.manifest.id).transaction {
            $0["transcript"] = ["status": "done", "reference": ["kind": "sidecar", "file": "transcript.json", "format": "cassini.words.v1"]]
            $0["speakers"] = (1...7).map { i -> [String: Any] in
                let nameValue: Any = i == 1 ? ("Silvio" as Any) : (i == 2 ? ("Ruurd" as Any) : NSNull())
                let prov = i <= 2 ? "user" : "unnamed"
                return ["id": "spk-\(i)", "name": nameValue, "provenance": prov, "colourIndex": i - 1]
            }
        }
        let items = (1...7).map { i -> [String: Any] in
            ["speaker": "spk-\(i)", "startMs": (i - 1) * 500, "endMs": i * 500, "text": "Word\(i)"]
        }
        try JSONSerialization.data(withJSONObject: ["language": "en", "items": items])
            .write(to: session.directory.appendingPathComponent("transcript.json"))
        let meeting = try #require(LibraryScanner(root: root).meeting(at: session.directory))
        LibraryLocationModel.shared.location = LibraryLocation(primary: root)

        let coordinator = MeetingRenameCoordinator()
        coordinator.showSpeaker(meeting, id: "spk-3")
        #expect(coordinator.presentation == .speakers)
        #expect(coordinator.canStepSpeaker(-1) && coordinator.canStepSpeaker(1))

        // Name spk-3 as Marta, then move to spk-4 and spk-5 without closing.
        coordinator.name = "Marta"
        coordinator.stepSpeaker(1)
        #expect(coordinator.speakerID == "spk-4")
        coordinator.isBackgroundVoice = true
        coordinator.selectSpeaker("spk-5")
        #expect(coordinator.speakerID == "spk-5")
        coordinator.isBackgroundVoice = true
        // Move back to spk-3: draft name is preserved.
        coordinator.selectSpeaker("spk-3")
        #expect(coordinator.name == "Marta")
        #expect(coordinator.canApply)

        // Save once: applies all changes and shows one summary toast with Undo.
        coordinator.apply()
        await coordinator.waitForShutdown()
        #expect(coordinator.presentation == nil)
        let saved = try #require(LibraryScanner(root: root).meeting(at: session.directory))
        #expect(saved.speaker(for: "spk-3")?.name == "Marta")
        #expect(saved.speaker(for: "spk-4")?.background == true)
        #expect(saved.speaker(for: "spk-5")?.background == true)
        #expect(coordinator.speakerEditToast?.message == "Named Marta · 2 background voices")

        // Undo puts everything back.
        coordinator.undoLastSpeakerEdit()
        await coordinator.waitForShutdown()
        #expect(coordinator.speakerEditToast == nil)
        let undone = try #require(LibraryScanner(root: root).meeting(at: session.directory))
        #expect(undone.speaker(for: "spk-3")?.name == nil)
        #expect(undone.speaker(for: "spk-4")?.background == false)
        #expect(undone.speaker(for: "spk-5")?.background == false)
    }

    @Test func backgroundVoiceToastFormatsSingleAndMultiple() {
        #expect(MeetingRenameCoordinator.toastMessage(named: [], newlyBackground: ["Speaker 5"], unbackgroundedCount: 0, locale: Locale(identifier: "en_GB"), language: .en) == "Speaker 5 is now a background voice")
        #expect(MeetingRenameCoordinator.toastMessage(named: ["Marta"], newlyBackground: ["Speaker 4", "Speaker 5", "Speaker 6", "Speaker 7"], unbackgroundedCount: 0, locale: Locale(identifier: "en_GB"), language: .en) == "Named Marta · 4 background voices")
        #expect(MeetingRenameCoordinator.toastMessage(named: [], newlyBackground: ["Speaker 4", "Speaker 5", "Speaker 6", "Speaker 7"], unbackgroundedCount: 0, locale: Locale(identifier: "en_GB"), language: .en) == "4 background voices")
        #expect(MeetingRenameCoordinator.toastMessage(named: ["Marta"], newlyBackground: [], unbackgroundedCount: 0, locale: Locale(identifier: "en_GB"), language: .en) == nil)
    }

    private func makeThreeSpeakerFixture() async throws -> (URL, LibraryMeeting) {
        try await Task.detached {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("SpeakerVoiceUndo-" + UUID().uuidString)
            let session = try RecordingSession(parent: root, title: "Standup", source: "macos")
            try session.addTrack(id: "mic", label: "Mic", kind: "microphone", sampleRate: 16000, channels: 1)
            try session.append(id: "mic", pcm: Data(repeating: 1, count: 32000), offsetMs: 0)
            try session.finish()
            try MeetingMetadataWriter(directory: session.directory, id: session.manifest.id).transaction {
                $0["transcript"] = ["status": "done", "reference": ["kind": "sidecar", "file": "transcript.json", "format": "cassini.words.v1"]]
                $0["speakers"] = [
                    ["id": "a", "name": "Alice", "provenance": "user", "colourIndex": 0],
                    ["id": "b", "name": "Bob", "provenance": "user", "colourIndex": 1],
                    ["id": "c", "name": NSNull(), "provenance": "unnamed", "colourIndex": 2],
                ]
            }
            let items: [[String: Any]] = [
                ["speaker": "a", "startMs": 0, "endMs": 500, "text": "Hello"],
                ["speaker": "b", "startMs": 500, "endMs": 900, "text": "Coffee"],
                ["speaker": "c", "startMs": 1000, "endMs": 1500, "text": "Agreed"],
            ]
            try JSONSerialization.data(withJSONObject: ["language": "en", "items": items])
                .write(to: session.directory.appendingPathComponent("transcript.json"))
            return (root, try #require(LibraryScanner(root: root).meeting(at: session.directory)))
        }.value
    }

    @Test func undoPreservesExistingSavedVoiceAfterNoOpEnrollment() async throws {
        let (root, meeting) = try await makeThreeSpeakerFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let voices = SavedVoicesController.shared
        let store = SavedVoicesStore(directory: root.appendingPathComponent("voices"))
        voices.store = store
        LibraryLocationModel.shared.location = LibraryLocation(primary: root)
        defer {
            voices.refreshAction = nil; voices.prepareAction = nil; voices.enrollAction = nil
            voices.prepared = nil; voices.snapshot = nil
        }

        let embeddingA = [Float](repeating: 1, count: 512)
        let clipA = VoiceClip(meeting: meeting.folder.lastPathComponent, speaker: "a", startMs: 0, endMs: 5000)
        let gen = try await store.snapshot().generation
        let voiceA = try await store.enroll(name: "Alice", embedding: embeddingA, seconds: 5, generation: gen, clip: clipA)
        voices.snapshot = try await store.snapshot()
        voices.refreshAction = { voices.snapshot = try? await store.snapshot() }
        voices.prepareAction = { _, id in
            guard id == "a" else { return nil }
            return .init(embedding: embeddingA, seconds: 5, generation: gen, clip: clipA)
        }
        voices.enrollAction = { prepared, name, id in
            let res = try await store.enrollReturningBackup(name: name, embedding: prepared.embedding, seconds: prepared.seconds, generation: prepared.generation, into: id, clip: prepared.clip)
            voices.snapshot = try await store.snapshot()
            return res.backup
        }

        // Exact repro: open already-remembered A, let preparation finish, switch to B, mark B background, Save, Undo.
        let coordinator = MeetingRenameCoordinator()
        coordinator.showSpeaker(meeting, id: "a")
        await waitForEnrollment(coordinator)
        coordinator.selectSpeaker("b")
        coordinator.isBackgroundVoice = true
        coordinator.apply()
        await coordinator.waitForShutdown()

        // No-op enrollment on A must not record a voice backup; A's saved voice stays intact.
        #expect(coordinator.speakerEditToast?.voiceBackups.isEmpty == true)
        let afterSave = try await store.snapshot()
        #expect(afterSave.voices.count == 1 && afterSave.voices[0].id == voiceA && afterSave.voices[0].count == 1)

        // Undo restores B and must NOT delete A's existing saved voice.
        coordinator.undoLastSpeakerEdit()
        await coordinator.waitForShutdown()
        let afterUndo = try await store.snapshot()
        #expect(afterUndo.voices.count == 1 && afterUndo.voices[0].id == voiceA && afterUndo.voices[0].count == 1)
        #expect(afterUndo.voiceID(meeting: meeting.folder.lastPathComponent, speaker: "a") == voiceA)
        #expect(LibraryScanner(root: root).meeting(at: meeting.folder)?.speaker(for: "b")?.background == false)
    }

    @Test func undoRestoresForgottenVoiceAndRevertsOnlyNewlyEnrolledVoice() async throws {
        let (root, meeting) = try await makeThreeSpeakerFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let voices = SavedVoicesController.shared
        let store = SavedVoicesStore(directory: root.appendingPathComponent("voices"))
        voices.store = store
        LibraryLocationModel.shared.location = LibraryLocation(primary: root)
        defer {
            voices.refreshAction = nil; voices.prepareAction = nil; voices.enrollAction = nil
            voices.prepared = nil; voices.snapshot = nil
        }

        let embeddingA = [Float](repeating: 1, count: 512)
        let embeddingC = [Float]([1, -1] + Array(repeating: 0, count: 510))
        let clipA = VoiceClip(meeting: meeting.folder.lastPathComponent, speaker: "a", startMs: 0, endMs: 5000)
        let clipC = VoiceClip(meeting: meeting.folder.lastPathComponent, speaker: "c", startMs: 1000, endMs: 6000)
        let gen = try await store.snapshot().generation
        let voiceA = try await store.enroll(name: "Alice", embedding: embeddingA, seconds: 5, generation: gen, clip: clipA)
        voices.snapshot = try await store.snapshot()
        voices.refreshAction = { voices.snapshot = try? await store.snapshot() }
        voices.prepareAction = { _, id in
            if id == "a" { return .init(embedding: embeddingA, seconds: 5, generation: gen, clip: clipA) }
            if id == "c" { return .init(embedding: embeddingC, seconds: 5, generation: gen, clip: clipC) }
            return nil
        }
        voices.enrollAction = { prepared, name, id in
            let res = try await store.enrollReturningBackup(name: name, embedding: prepared.embedding, seconds: prepared.seconds, generation: prepared.generation, into: id, clip: prepared.clip)
            voices.snapshot = try await store.snapshot()
            return res.backup
        }

        // Forget A, enroll C as "Carol", mark B as background, Save -> A gone, C enrolled.
        let coordinator = MeetingRenameCoordinator()
        coordinator.showSpeaker(meeting, id: "a")
        await waitForEnrollment(coordinator)
        coordinator.rememberVoice = false
        coordinator.selectSpeaker("c")
        await waitForEnrollment(coordinator)
        coordinator.name = "Carol"
        coordinator.rememberVoice = true
        coordinator.selectSpeaker("b")
        coordinator.isBackgroundVoice = true
        coordinator.apply()
        await coordinator.waitForShutdown()

        let afterSave = try await store.snapshot()
        #expect(afterSave.voiceID(meeting: meeting.folder.lastPathComponent, speaker: "a") == nil)
        #expect(afterSave.voiceID(meeting: meeting.folder.lastPathComponent, speaker: "c") != nil)
        #expect(afterSave.voices.map(\.name) == ["Carol"])

        // Undo removes Carol and restores Alice verbatim (same voice ID).
        coordinator.undoLastSpeakerEdit()
        await coordinator.waitForShutdown()
        let afterUndo = try await store.snapshot()
        #expect(afterUndo.voices.count == 1)
        #expect(afterUndo.voices[0].id == voiceA && afterUndo.voices[0].name == "Alice")
        #expect(afterUndo.voiceID(meeting: meeting.folder.lastPathComponent, speaker: "a") == voiceA)
        #expect(afterUndo.voiceID(meeting: meeting.folder.lastPathComponent, speaker: "c") == nil)
    }

    @Test func undoRecordsOnlyCommittedVoiceChangesWhenEnrollmentFails() async throws {
        let (root, meeting) = try await makeThreeSpeakerFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let voices = SavedVoicesController.shared
        let store = SavedVoicesStore(directory: root.appendingPathComponent("voices"))
        voices.store = store
        LibraryLocationModel.shared.location = LibraryLocation(primary: root)
        defer {
            voices.refreshAction = nil; voices.prepareAction = nil; voices.enrollAction = nil
            voices.prepared = nil; voices.snapshot = nil
        }

        let embeddingA = [Float](repeating: 1, count: 512)
        let embeddingC = [Float]([1, -1] + Array(repeating: 0, count: 510))
        let clipA = VoiceClip(meeting: meeting.folder.lastPathComponent, speaker: "a", startMs: 0, endMs: 5000)
        let clipC = VoiceClip(meeting: meeting.folder.lastPathComponent, speaker: "c", startMs: 1000, endMs: 6000)
        let gen = try await store.snapshot().generation
        let voiceA = try await store.enroll(name: "Alice", embedding: embeddingA, seconds: 5, generation: gen, clip: clipA)
        voices.snapshot = try await store.snapshot()
        voices.refreshAction = { voices.snapshot = try? await store.snapshot() }
        voices.prepareAction = { _, id in
            if id == "a" { return .init(embedding: embeddingA, seconds: 5, generation: gen, clip: clipA) }
            if id == "c" { return .init(embedding: embeddingC, seconds: 5, generation: gen, clip: clipC) }
            return nil
        }
        // Fail enrollment for Carol after Alice's forget has already committed.
        voices.enrollAction = { _, _, _ in throw SavedVoicesError.unavailable }

        let coordinator = MeetingRenameCoordinator()
        coordinator.showSpeaker(meeting, id: "a")
        await waitForEnrollment(coordinator)
        coordinator.rememberVoice = false
        coordinator.selectSpeaker("c")
        await waitForEnrollment(coordinator)
        coordinator.name = "Carol"
        coordinator.rememberVoice = true
        coordinator.selectSpeaker("b")
        coordinator.isBackgroundVoice = true
        coordinator.apply()
        await coordinator.waitForShutdown()

        // Alice was forgotten before Carol's enrollment threw; only Alice's committed change is backed up.
        #expect(coordinator.voiceChangeFailed)
        #expect(coordinator.speakerEditToast?.voiceBackups.map(\.speaker) == ["a"])
        #expect(try await store.snapshot().voices.isEmpty)

        // Undo restores Alice's voice and does not fail on Carol's uncommitted enrollment.
        coordinator.undoLastSpeakerEdit()
        await coordinator.waitForShutdown()
        #expect(!coordinator.voiceChangeFailed)
        let restored = try await store.snapshot()
        #expect(restored.voices.count == 1 && restored.voices[0].id == voiceA)
        #expect(restored.voiceID(meeting: meeting.folder.lastPathComponent, speaker: "a") == voiceA)
    }

    @MainActor private final class PrepareCounter { var count = 0 }

    @Test(.timeLimit(.minutes(1)))
    func revisitingSpeakerRestartsCanceledVoicePreparation() async throws {
        let (root, meeting) = try await makeThreeSpeakerFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let voices = SavedVoicesController.shared
        let store = SavedVoicesStore(directory: root.appendingPathComponent("voices"))
        voices.store = store
        LibraryLocationModel.shared.location = LibraryLocation(primary: root)
        let suite = "io.codemyriad.cassini.speaker-revisit." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        let previousPreferences = VoicePreferences.shared
        VoicePreferences.shared = VoicePreferences(defaults: defaults)
        VoicePreferences.shared.remember = true

        let firstPrepareGate = RefreshGate()
        let (firstPrepareCanceled, markFirstPrepareCanceled) = AsyncStream<Void>.makeStream()
        let aPrepareAttempts = PrepareCounter()
        let coordinator = MeetingRenameCoordinator()
        defer {
            firstPrepareGate.resume()
            markFirstPrepareCanceled.finish()
            coordinator.cancel()
            voices.refreshAction = nil; voices.prepareAction = nil; voices.enrollAction = nil
            voices.prepared = nil; voices.snapshot = nil
            VoicePreferences.shared = previousPreferences
            defaults.removePersistentDomain(forName: suite)
        }

        // Seed an existing saved voice from an earlier meeting so VoiceMatcher produces a ranked candidate for A.
        let embeddingA = [Float](repeating: 1, count: 512)
        let clipA = VoiceClip(meeting: meeting.folder.lastPathComponent, speaker: "a", startMs: 0, endMs: 5000)
        let initialGen = try await store.snapshot().generation
        let existingVoiceID = try await store.enroll(
            name: "Alice Prior",
            embedding: embeddingA,
            seconds: 5,
            generation: initialGen,
            clip: VoiceClip(meeting: "earlier-meeting", speaker: "a", startMs: 0, endMs: 5000)
        )
        let seededSnapshot = try await store.snapshot()
        voices.snapshot = seededSnapshot
        voices.refreshAction = { voices.snapshot = try? await store.snapshot() }
        voices.prepareAction = { _, id in
            guard id == "a" else { return nil }
            aPrepareAttempts.count += 1
            if aPrepareAttempts.count == 1 {
                await firstPrepareGate.pause()
                if Task.isCancelled {
                    markFirstPrepareCanceled.yield(())
                    markFirstPrepareCanceled.finish()
                    throw CancellationError()
                }
            }
            return .init(embedding: embeddingA, seconds: 5, generation: seededSnapshot.generation, clip: clipA)
        }
        voices.enrollAction = { prepared, name, id in
            let res = try await store.enrollReturningBackup(
                name: name,
                embedding: prepared.embedding,
                seconds: prepared.seconds,
                generation: prepared.generation,
                into: id,
                clip: prepared.clip
            )
            voices.snapshot = try await store.snapshot()
            return res.backup
        }

        // 1. Open speaker A; wait until excerpt prep finishes and voice prep suspends in prepare().
        coordinator.showSpeaker(meeting, id: "a")
        await firstPrepareGate.waitUntilEntered()
        #expect(coordinator.speakerDrafts["a"]?.excerptPrepared == true)
        #expect(coordinator.speakerDrafts["a"]?.voicePrepared == false)
        #expect(!coordinator.speakerPreparing)
        #expect(coordinator.speakerQuote == "Hello")
        #expect(coordinator.voiceEnrollment == nil)
        #expect(coordinator.voiceCandidates.isEmpty)
        #expect(!coordinator.canChangeRememberVoice)

        // 2. Switch away to B while A's voice preparation is in flight -> cancels A's voice prep.
        coordinator.selectSpeaker("b")
        for await _ in firstPrepareCanceled { break }
        #expect(coordinator.speakerDrafts["a"]?.excerptPrepared == true)
        #expect(coordinator.speakerDrafts["a"]?.voicePrepared == false)
        #expect(coordinator.speakerDrafts["a"]?.voicePreparationFailed == false)

        // 3. Switch back to A -> excerpt stays prepared, canceled voice prep restarts and finishes.
        coordinator.selectSpeaker("a")
        #expect(!coordinator.speakerPreparing)
        await waitForEnrollment(coordinator)
        #expect(aPrepareAttempts.count == 2)
        #expect(coordinator.speakerDrafts["a"]?.excerptPrepared == true)
        #expect(coordinator.speakerDrafts["a"]?.voicePrepared == true)
        #expect(!coordinator.voicePreparationFailed)
        #expect(coordinator.voiceCandidates.map(\.id) == [existingVoiceID])
        #expect(coordinator.voiceCandidates.first?.score != nil)
        #expect(coordinator.canChangeRememberVoice)

        // 4. Saving enrolls A's voice instead of silently skipping enrollment.
        coordinator.rememberVoice = true
        coordinator.apply()
        await coordinator.waitForShutdown()
        #expect(!coordinator.voiceChangeFailed)
        let afterSave = try await store.snapshot()
        #expect(afterSave.voiceID(meeting: meeting.folder.lastPathComponent, speaker: "a") != nil)
    }
}
