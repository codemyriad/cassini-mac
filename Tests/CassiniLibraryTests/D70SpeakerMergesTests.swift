// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
import CassiniKit
import CassiniRecording
@testable import CassiniLibrary

/// D70 item 11 (D24/UX16): meeting.json speakerMerges is decoded and applied when a meeting is
/// read. Merged speakers show, group and search as their final target; transcript.json and the
/// words writers use keep their own speaker ids. Mac writes no merges yet (M4).
struct D70SpeakerMergesTests {
    private typealias Entry = SpeakerMerges.Entry
    private func entries(_ pairs: [(String,String)]) -> [Entry] { pairs.map { Entry(from:$0.0,into:$0.1) } }

    // MARK: resolver (ports of GNOME tests/test_speakers.py, plus chains)

    @Test func unknownSelfAndCycleEntriesAreIgnored() {
        let merged = SpeakerMerges.resolve(entries([("a","b"),("b","a"),("unknown","c"),("c","unknown"),("c","c")]),known:["a","b","c"])
        #expect(merged == ["a":"b"])
        let words = ["a","b","c"].map { LibraryTranscriptItem(speaker:$0,startMs:0,endMs:1,text:$0) }
        #expect(SpeakerMerges.apply(words,merged).map(\.speaker) == ["b","b","c"])
        #expect(SpeakerMerges.apply(words,merged).map(\.text) == ["a","b","c"],"only the speaker changes")
    }
    @Test func nothingIsKnownSoNothingMerges() {
        #expect(SpeakerMerges.resolve(entries([("a","b"),("b","c"),("c","a")]),known:[]) == [:])
    }
    @Test func chainsResolveToTheFinalTarget() {
        let known: Set<String> = ["a","b","c","d"]
        #expect(SpeakerMerges.resolve(entries([("a","b"),("b","c")]),known:known) == ["a":"c","b":"c"])
        #expect(SpeakerMerges.resolve(entries([("b","c"),("a","b")]),known:known) == ["a":"c","b":"c"])
        #expect(SpeakerMerges.resolve(entries([("a","b"),("c","a")]),known:known) == ["a":"b","c":"b"])
        #expect(SpeakerMerges.resolve(entries([("a","b"),("a","b")]),known:known) == ["a":"b"],"a duplicate changes nothing")
        #expect(SpeakerMerges.resolve(entries([("a","b"),("b","c"),("c","a")]),known:known) == ["a":"c","b":"c"],"the cycle-closing entry is ignored")
        #expect(SpeakerMerges.resolve(entries([("a","b"),("a","c")]),known:known) == ["a":"c"],"a later entry for the same from replaces it (GNOME parity)")
    }
    @Test func undoingTheLastMergeRestoresTheEarlierOne() {
        let known: Set<String> = ["a","b","c"]
        let history = entries([("a","b"),("b","c")])
        #expect(SpeakerMerges.resolve(history,known:known) == ["a":"c","b":"c"])
        #expect(SpeakerMerges.resolve(Array(history.dropLast()),known:known) == ["a":"b"])
    }
    @Test func aTargetSplitsOnTheGapRangesOfEverySpeakerMergedIntoIt() {
        let ranges: SpeakerGapRanges.Ranges = ["a":[100..<200],"c":[500..<600],"b":[]]
        let gaps = SpeakerMerges.gaps(ranges,["a":"c","b":"c"])
        #expect(gaps["c"] == [100..<200,500..<600])
        #expect(gaps["a"] == [100..<200],"the unmerged entry stays (no word carries it)")
        #expect(SpeakerMerges.gaps(ranges,[:]) == ranges)
        let first = LibraryTranscriptItem(speaker:"c",startMs:0,endMs:10,text:"x")    // M = 80
        let second = LibraryTranscriptItem(speaker:"c",startMs:20,endMs:30,text:"y")  // M = 400
        #expect(SpeakerGapRanges.splits(first,second,gaps),"a's gap now splits a turn of c")
        #expect(!SpeakerGapRanges.splits(first,second,ranges))
    }

    // MARK: the scanner

    private struct Fixture { let root: URL; let folder: URL; let id: UUID }
    private func meeting(speakers: [[String:Any]], merges: Any?, words: [(String,Int64,Int64,String)]) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("D70Merges-"+UUID().uuidString)
        let session = try RecordingSession(parent:root,title:"Call",source:"macos")
        try session.addTrack(id:"mic",label:"Mic",kind:"microphone",sampleRate:16000,channels:1)
        try session.append(id:"mic",pcm:Data(repeating:1,count:32000),offsetMs:0); try session.finish()
        try MeetingMetadataWriter(directory:session.directory,id:session.manifest.id).transaction { metadata in
            metadata["transcript"] = ["status":"done","reference":["kind":"sidecar","file":"transcript.json","format":"cassini.words.v1"]]
            metadata["speakers"] = speakers
            if let merges { metadata["speakerMerges"] = merges }
        }
        let items = words.map { ["speaker":$0.0,"startMs":$0.1,"endMs":$0.2,"text":$0.3] as [String:Any] }
        try JSONSerialization.data(withJSONObject:["language":"en","items":items],options:[.sortedKeys])
            .write(to:session.directory.appendingPathComponent("transcript.json"))
        return .init(root:root,folder:session.directory,id:session.manifest.id)
    }
    private func read(_ fixture: Fixture) throws -> LibraryMeeting {
        try #require(try LibraryScanner(root:fixture.root).scan().meetings.first)
    }
    private let three: [[String:Any]] = [
        ["id":"me","name":"Me","provenance":"source","colourIndex":0],
        ["id":"track-a","name":NSNull(),"provenance":"unnamed","colourIndex":1,"label":"Speaker 1"],
        ["id":"track-c","name":"Carla","provenance":"user","colourIndex":2],
    ]
    private let conversation: [(String,Int64,Int64,String)] = [
        ("me",0,400,"Hello"),("track-a",500,900,"Hi"),("track-c",1000,1400,"there,"),("track-a",1500,1900,"all"),("me",2000,2400,"Good")]

    @Test func aMergedSpeakerShowsGroupsAndQuotesAsItsTarget() throws {
        let fixture = try meeting(speakers:three,merges:[["from":"track-a","into":"track-c"]],words:conversation)
        defer { try? FileManager.default.removeItem(at:fixture.root) }
        let transcript = fixture.folder.appendingPathComponent("transcript.json")
        let before = try Data(contentsOf:transcript)
        let meeting = try read(fixture)
        #expect(meeting.mergedInto == ["track-a":"track-c"])
        #expect(meeting.speakers.map(\.id) == ["me","track-c"],"the merged speaker leaves the pane")
        #expect(meeting.speakers.map(\.displayName) == ["Me","Carla"],"the target keeps its own name")
        #expect(meeting.speakers.map(\.colourIndex) == [0,1],"colours follow first speaking after the merge")
        #expect(meeting.transcriptItems.map(\.speaker) == ["me","track-c","track-c","track-c","me"])
        #expect(meeting.writtenTranscriptItems.map(\.speaker) == conversation.map(\.0),"writers see the stored ids")
        #expect(meeting.transcriptTurns.map(\.speaker) == ["me","track-c","me"],"adjacent turns of a and c become one")
        #expect(meeting.transcriptTurns[1].text == "Hi there, all")
        #expect(MeetingPresentation.turns(meeting.transcriptItems,gaps:meeting.speakerGaps).count == 3)
        #expect(meeting.speakerNames == ["Me","Carla"])
        #expect(try Data(contentsOf:transcript) == before,"transcript.json is never rewritten")
    }
    @Test func aRejoinedSpeakerIsOneTurn() throws {
        let fixture = try meeting(speakers:three,merges:[["from":"track-c","into":"track-a"]],
                                  words:[("track-a",0,400,"one"),("track-c",500,900,"two"),("track-a",1000,1400,"three")])
        defer { try? FileManager.default.removeItem(at:fixture.root) }
        let meeting = try read(fixture)
        #expect(meeting.transcriptTurns.map(\.text) == ["one two three"])
        #expect(meeting.speakers.map(\.displayName) == ["Speaker 1"])
    }
    @Test func withoutMergesNothingChanges() throws {
        for merges in [nil,[] as [Any],[["from":"nobody","into":"track-c"],["from":"track-a","into":"track-a"]] as Any] as [Any?] {
            let fixture = try meeting(speakers:three,merges:merges,words:conversation)
            defer { try? FileManager.default.removeItem(at:fixture.root) }
            let meeting = try read(fixture)
            #expect(meeting.issues.isEmpty,"ignored entries never invalidate the meeting")
            #expect(meeting.mergedInto.isEmpty)
            #expect(meeting.speakers.map(\.id) == ["me","track-a","track-c"])
            #expect(meeting.transcriptItems == meeting.writtenTranscriptItems)
        }
    }
    @Test func aChainShowsEveryMergedIdAsTheLastTargetAndUndoRestores() throws {
        let fixture = try meeting(speakers:three,merges:[["from":"track-a","into":"track-c"],["from":"track-c","into":"me"]],words:conversation)
        defer { try? FileManager.default.removeItem(at:fixture.root) }
        #expect(try read(fixture).speakers.map(\.displayName) == ["Me"])
        // Undo merge removes the last entry (written by GNOME or a later Mac): A→C is back.
        try MeetingMetadataWriter(directory:fixture.folder,id:fixture.id).transaction { $0["speakerMerges"] = [["from":"track-a","into":"track-c"]] }
        #expect(try read(fixture).speakers.map(\.displayName) == ["Me","Carla"])
    }
    @Test func aMalformedHistoryIsInvalidMetadataLikeAnyOtherSchemaViolation() throws {
        let fixture = try meeting(speakers:three,merges:nil,words:conversation)
        defer { try? FileManager.default.removeItem(at:fixture.root) }
        // Written directly: Mac's writer refuses to write a file its schema rejects.
        let url = fixture.folder.appendingPathComponent("meeting.json")
        var document = try #require(try JSONSerialization.jsonObject(with:Data(contentsOf:url)) as? [String:Any])
        document["speakerMerges"] = [["from":"","into":"track-c"]]
        try JSONSerialization.data(withJSONObject:document,options:[.sortedKeys]).write(to:url)
        #expect(try read(fixture).issues.contains(.invalidMetadata))
    }
    @Test func macWritersKeepTheHistoryVerbatim() throws {
        let fixture = try meeting(speakers:three,merges:[["from":"track-a","into":"track-c","by":"gnome"]],words:conversation)
        defer { try? FileManager.default.removeItem(at:fixture.root) }
        let url = fixture.folder.appendingPathComponent("meeting.json")
        // The writer re-encodes the file; the value, member order and literals must be unchanged.
        func history() throws -> JSON? { try JSONParser.parse(Data(contentsOf:url))["speakerMerges"] }
        let before = try history()
        let writer = try MeetingMetadataWriter(directory:fixture.folder,id:fixture.id)
        try writer.transaction { metadata in   // a rename on Mac
            var speakers = metadata["speakers"] as! [[String:Any]]
            speakers[2]["name"] = "Carla R."; metadata["speakers"] = speakers
        }
        try writer.transaction { $0["title"] = "Renamed call"; $0["titleSource"] = "user" }
        let after = try history()
        #expect(before != nil && after == before,"the history and its unknown member are unchanged")
        let meeting = try read(fixture)
        #expect(meeting.speakers.map(\.displayName) == ["Me","Carla R."])
    }
}
