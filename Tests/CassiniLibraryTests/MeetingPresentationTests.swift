// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
import CassiniKit
@testable import CassiniLibrary

struct MeetingPresentationTests {
    @Test func openingVerifiedWordsKeepsTheirIdentityAndText() throws {
        let f = try Fixture()
        let base = try Data(contentsOf:f.repository.appendingPathComponent("Tests/CassiniKitTests/Conformance/opus/001-minimal-v1.opus"))
        let parsed = try CassiniReader.read(base), id = UUID()
        var manifest = try #require(parsed.manifest?.raw)
        manifest = try manifest.setting("meeting",to:#require(manifest["meeting"]).setting("id",to:.string(id.uuidString.lowercased())))
        let speaker = try #require(parsed.manifest?.speakers.first?.id)
        let body = try JSONSerialization.data(withJSONObject:["items":[["speaker":speaker,"startMs":0,"endMs":100,"text":"Verified words"]]])
        let tags = try PortableMeetingTags.make(manifest:manifest,transcript:body,wordCount:1)
        let url = f.root.appendingPathComponent("Verified.opus")
        _ = try OpusStreamFile.rewrite(base,tags:tags,to:url)
        let file = try CassiniReader.read(contentsOf:url)
        let meeting = MeetingPresentation.external(file,url:url)
        #expect(file.state == .ok && meeting.state.transcript == .done)
        #expect(meeting.transcriptItems.map(\.text) == ["Verified words"] && !meeting.canWriteDown)
        #expect(meeting.id == id)
    }
    @Test(arguments: ["[]", "null"]) func openingEmptyWordsKeepsWriteDownAvailable(items: String) throws {
        let f = try Fixture()
        let base = try Data(contentsOf:f.repository.appendingPathComponent("Tests/CassiniKitTests/Conformance/opus/001-minimal-v1.opus"))
        let manifest = try #require(CassiniReader.read(base).manifest?.raw)
        let tags = try PortableMeetingTags.make(manifest:manifest,transcript:Data("{\"items\":\(items)}".utf8),wordCount:0)
        let url = f.root.appendingPathComponent("No words.opus")
        _ = try OpusStreamFile.rewrite(base,tags:tags,to:url)
        let file = try CassiniReader.read(contentsOf:url)
        #expect(file.state == .ok)
        let meeting = MeetingPresentation.external(file,url:url)
        #expect(meeting.state.transcript == .none && meeting.canWriteDown)
        #expect(meeting.state.audioAvailable == true && meeting.audioFiles == [url])
        #expect(meeting.transcriptItems.isEmpty && meeting.speakers.isEmpty)
    }
    @Test func openingUnverifiedWordsDoesNotAuthenticateThem() throws {
        let f = try Fixture()
        let base = try Data(contentsOf:f.repository.appendingPathComponent("Tests/CassiniKitTests/Conformance/opus/001-minimal-v1.opus"))
        var manifest = try #require(CassiniReader.read(base).manifest?.raw)
        let id = UUID()
        manifest = try manifest.setting("meeting",to:#require(manifest["meeting"]).setting("id",to:.string(id.uuidString.lowercased())))
        manifest = try manifest.setting("integrity",to:#require(manifest["integrity"]).setting("matchPolicy",to:.string("future-policy")))
        let body = Data("{\"items\":[{\"speaker\":\"untrusted\",\"startMs\":0,\"endMs\":100,\"text\":\"Untrusted words\"}]}".utf8)
        let tags = try PortableMeetingTags.make(manifest:manifest,transcript:body,wordCount:1)
        let url = f.root.appendingPathComponent("Unknown policy.opus")
        _ = try OpusStreamFile.rewrite(base,tags:tags,to:url)
        let file = try CassiniReader.read(contentsOf:url)
        #expect(file.state == .unverified)
        let meeting = MeetingPresentation.external(file,url:url)
        #expect(meeting.state.transcript == .damaged && meeting.transcriptItems.isEmpty)
        #expect(meeting.speakers.isEmpty && meeting.state.audioAvailable == true)
        #expect(meeting.id != id)
    }
    @Test func captureSourceNamesAreAcceptedOnlyWithNames() throws {
        let f = try Fixture()
        try f.metadata { $0["speakers"] = [["id": "me", "name": "Me", "provenance": "source", "colourIndex": 0]] }
        let path = f.folder.appendingPathComponent("meeting.json")
        let parsed = try AppMetadata.parse(Data(contentsOf: path))
        #expect(parsed.speakers.first?.provenance == .source && parsed.speakers.first?.name == "Me")
        try f.metadata { $0["speakers"] = [["id": "me", "name": NSNull(), "provenance": "source", "colourIndex": 0]] }
        #expect(throws: MetadataError.self) { try AppMetadata.parse(Data(contentsOf: path)) }
    }
    @Test func sharesUseLargestRemainderWithFirstSpeakingTies() {
        var meeting = LibraryMeeting(id: UUID(), folder: URL(fileURLWithPath: "/fixture"), state: .init(), title: nil,
            start: nil, durationMs: nil, speakers: ["a", "b", "c"].enumerated().map { .init(id: $0.element, provenance: .unnamed, colourIndex: $0.offset) }, quote: nil, notes: [], audioFiles: [], issues: [])
        meeting.transcriptItems = ["a", "b", "c"].map { .init(speaker: $0, startMs: 0, endMs: 1000, text: $0) }
        #expect(MeetingPresentation.shares(meeting) == ["a": 34, "b": 33, "c": 33])
        meeting.transcriptItems = [.init(speaker: "a", startMs: 0, endMs: 23000, text: "a"), .init(speaker: "b", startMs: 0, endMs: 19000, text: "b"), .init(speaker: "c", startMs: 0, endMs: 11000, text: "c")]
        #expect(MeetingPresentation.shares(meeting) == ["a": 43, "b": 36, "c": 21])
        meeting.transcriptItems = []
        #expect(MeetingPresentation.shares(meeting).values.allSatisfy { $0 == 0 })
    }
    @Test func turnsRetainExactSentenceAndWordBoundaries() {
        let items: [LibraryTranscriptItem] = [.init(speaker: "a", startMs: 0, endMs: 3000, text: "One sentence."), .init(speaker: "a", startMs: 4000, endMs: 4500, text: "One"), .init(speaker: "b", startMs: 4100, endMs: 4900, text: "yes")]
        let turns = MeetingPresentation.turns(items)
        #expect(turns.count == 2 && turns[0].items == Array(items.prefix(2)) && turns[1].startMs == 4100)
    }
}

struct TurnQuotePresentationTests {
    @Test func quotePartnersNeverCrossTurnsAndRawWordsStayIntact() {
        let items: [LibraryTranscriptItem] = [
            .init(speaker:"a",startMs:0,endMs:10,text:"He said \"hello"),
            .init(speaker:"a",startMs:10,endMs:20,text:"world\"."),
            .init(speaker:"b",startMs:20,endMs:30,text:"\"Unpaired"),
            .init(speaker:"a",startMs:30,endMs:40,text:"Closing\"")]
        let turns = MeetingPresentation.turns(items)
        #expect(turns.map { $0.items.map(\.text).joined(separator:" ") } == ["He said “hello world”.","Unpaired","Closing"])
        #expect(turns.flatMap(\.items).map(\.startMs) == items.map(\.startMs))
        #expect(turns.flatMap(\.items).map(\.endMs) == items.map(\.endMs))
        #expect(items[0].text == "He said \"hello")
        #expect(LibraryTranscriptTurn.coalescing(items).map(\.text) == ["He said “hello world”.","Unpaired","Closing"])
        let markdown = MeetingMarkdown.render(title:"Test",start:nil,durationMs:nil,timeZone:TimeZone(secondsFromGMT:0)!,names:[:],items:items,notes:[])
        #expect(markdown.contains("He said “hello world”.") && !markdown.contains("\"Unpaired"))
    }
}
