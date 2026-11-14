// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
import CassiniLibrary
import CassiniRecording

@MainActor @Suite(.serialized) struct CoordinatorTests {
    private func fixture() throws -> (URL,LibraryMeeting) {
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
        SavedVoicesController.shared.store=SavedVoicesStore(directory:broken)
        LibraryLocationModel.shared.location=LibraryLocation(primary:root)
        return (root,try #require(LibraryScanner(root:root).meeting(at:session.directory)))
    }
    @Test func dialogMergeClosesAfterVoiceFailureAndNextShowClearsFailure() async throws {
        let (root,meeting)=try fixture()
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
        let (root,meeting)=try fixture()
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
}
