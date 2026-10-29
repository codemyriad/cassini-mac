// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import CassiniLibrary

struct NoSpeechTests {
    @Test func completedEmptyTranscriptOffersExplicitRetryOnly() throws {
        let fixture = try Fixture()
        try Data("{\"items\":[]}".utf8).write(to:fixture.folder.appendingPathComponent("transcript.json"))
        try fixture.metadata { $0["transcript"] = ["status":"done","reference":["kind":"sidecar","file":"transcript.json","format":"cassini.words.v1"]] }
        var meeting = try #require(LibraryScanner(root:fixture.root).scan().meetings.first)
        #expect(meeting.hasNoSpeech && meeting.canWriteDown && !meeting.canQueueAutomatically)
        meeting.metadataReadOnly = true
        #expect(meeting.hasNoSpeech && !meeting.canWriteDown)
        meeting.metadataReadOnly = false
        meeting.transcriptItems = [.init(speaker:"a",startMs:0,endMs:100,text:"A word")]
        #expect(!meeting.hasNoSpeech && !meeting.canWriteDown)
        meeting.transcriptItems = []; meeting.state.audioAvailable = false; meeting.audioFiles = []
        #expect(!meeting.hasNoSpeech && !meeting.canWriteDown)
    }
    @Test func unattemptedOrFailedTranscriptIsNotNoSpeech() throws {
        let fixture = try Fixture()
        for status in ["none","queued","running","failed","damaged"] {
            try fixture.metadata { $0["transcript"] = ["status":status,"reference":NSNull()] }
            let meeting = try #require(LibraryScanner(root:fixture.root).scan().meetings.first)
            #expect(!meeting.hasNoSpeech)
        }
    }
}
