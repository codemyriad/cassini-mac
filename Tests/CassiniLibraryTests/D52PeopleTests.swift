// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
import CassiniRecording
@testable import CassiniLibrary

/// D52 M12: "The others" (system sound) is a mixed source, not a person.
struct D52PeopleTests {
    @Test func theMixedOthersSourceIsLeftOutOfRowNamesAndPeople() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("D52People-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let session = try RecordingSession(parent:root,title:"Call",source:"macos")
        try session.addTrack(id:"mic",label:"Mic",kind:"microphone",sampleRate:16000,channels:1)
        try session.append(id:"mic",pcm:Data(repeating:1,count:32000),offsetMs:0); try session.finish()
        try MeetingMetadataWriter(directory:session.directory,id:session.manifest.id).transaction { metadata in
            metadata["transcript"] = ["status":"done","reference":["kind":"sidecar","file":"transcript.json","format":"cassini.words.v1"]]
            metadata["speakers"] = [["id":"me","name":"Me","provenance":"source","colourIndex":0],
                                    ["id":"others","name":"The others","provenance":"source","colourIndex":1],
                                    ["id":"track-guest","name":"Ana","provenance":"user","colourIndex":2]]
        }
        let words: [String:Any] = ["language":"en","items":[["speaker":"me","startMs":0,"endMs":500,"text":"Hello"],
            ["speaker":"others","startMs":600,"endMs":900,"text":"Hi"],["speaker":"track-guest","startMs":1000,"endMs":1500,"text":"Morning"]]]
        try JSONSerialization.data(withJSONObject:words).write(to:session.directory.appendingPathComponent("transcript.json"))
        let meeting = try #require(try LibraryScanner(root:root).scan().meetings.first)
        #expect(meeting.speakers.map(\.id) == ["me","others","track-guest"],"the speaker row itself stays")
        #expect(meeting.people.map(\.id) == ["me","track-guest"])
        #expect(meeting.speakerNames == ["Me","Ana"])
        #expect(LibraryFormat.rowMeta(durationMs:nil,names:meeting.speakerNames,locale:Locale(identifier:"en_GB"),language:.en) == "Me, Ana")
    }
}
