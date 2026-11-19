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

}
