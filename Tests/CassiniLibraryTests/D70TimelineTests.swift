// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import CassiniLibrary

@Suite struct D70TimelineTests {
    private func word(_ speaker: String, _ start: Int64, _ end: Int64) -> LibraryTranscriptItem {
        .init(speaker:speaker,startMs:start,endMs:end,text:"Agreed.")
    }
    @Test func readoutFindsSilenceInsideUnsplitTurnsAndRestoresOverlappedHost() {
        let words = [word("claire",100,900),word("guest",300,600),word("claire",1500,1800)]
        let index = TimelineReadout(items:words)
        #expect(index.speaker(at:99) == nil)
        #expect(index.speaker(at:100) == "claire")
        #expect(index.speaker(at:300) == "guest")
        #expect(index.speaker(at:599.9) == "guest")
        #expect(index.speaker(at:600) == "claire")
        #expect(index.speaker(at:900) == nil)
        #expect(index.speaker(at:1500) == "claire")
        #expect(index.speaker(at:1800) == nil)
        #expect(index.speaker(at:.nan) == nil)
        #expect(index.speaker(at:.infinity) == nil)
        let unsplit = [word("claire",100,200),word("claire",2000,2200)]
        #expect(SpeakerTurn.grouping(unsplit).count == 1)
        #expect(TimelineReadout(items:unsplit).speaker(at:1000) == nil)
    }
    @Test func equalStartsAndEndsHaveStableHalfOpenResolution() {
        let words = [word("sam",0,300),word("guest",0,100),word("ada",300,500),word("bad",400,400)]
        let index = TimelineReadout(items:words)
        #expect(index.speaker(at:0) == "guest")
        #expect(index.speaker(at:100) == "sam")
        #expect(index.speaker(at:300) == "ada")
        #expect(index.speaker(at:500) == nil)
        #expect(TimelineReadout().speaker(at:0) == nil)
    }
    @Test func stalePreparedIdsUseCurrentMergedNamesAndMetadata() throws {
        let words = [word("old",100,200),word("target",300,400),word("unlisted",500,600)]
        let cached = TimelineReadout(items:words)
        let cachedTurns = SpeakerTurn.grouping(words)
        var meeting = LibraryMeeting(id:UUID(),folder:URL(fileURLWithPath:"/synthetic"),
            state:.init(lifecycle:.saved,origin:.own,transcript:.done),title:nil,start:nil,durationMs:1000,
            speakers:[.init(id:"target",name:"Claire Lee",provenance:.user,colourIndex:2)],quote:nil,notes:[],audioFiles:[],issues:[])
        meeting.mergedInto = ["old":"target","another-old":"target","orphan":"absent"]
        #expect(cached.speaker(at:150) == "old")
        #expect(cached.speaker(at:250) == nil)
        let stale = try #require(cached.speaker(at:150))
        #expect(meeting.speakerDisplayNames[stale] == "Claire Lee")
        #expect(meeting.speaker(for:cachedTurns[0].speaker) == meeting.speakers[0])
        #expect(meeting.speaker(for:"another-old")?.colourIndex == 2)
        #expect(meeting.speaker(for:"old")?.provenance == .user)
        #expect(meeting.speaker(for:"unlisted") == nil && meeting.speaker(for:"orphan") == nil)
        #expect(meeting.speakerDisplayNames["orphan"] == nil)
        meeting.speakers[0].name = "Claire Morgan"
        #expect(meeting.speakerDisplayNames["old"] == "Claire Morgan")
        #expect(meeting.speaker(for:"old")?.displayName == "Claire Morgan")
    }
    @Test func sixPointSnapUsesNativeThumbTravelAtEveryWidth() {
        let timeline = ListeningTimeline(turns:SpeakerTurn.grouping([word("ada",10000,10300),word("sam",15000,16000),word("ada",20000,20300)]).filter { $0.speaker == "ada" })
        for width in [80.0,240,800] {
            let track = ListeningTimeline.Track(minX:12,width:width-24)
            for start in timeline.starts {
                let x = track.x(at:start,duration:40000)
                for delta in [-6.0,-5,0,5,6] {
                    let raw = track.position(at:x+delta,duration:40000)
                    #expect(timeline.snapped(raw,duration:40000,track:track) == start)
                }
                let raw = track.position(at:x+6.01,duration:40000)
                #expect(timeline.snapped(raw,duration:40000,track:track) == raw)
            }
            #expect(track.position(at:-100,duration:40000) == 0)
            #expect(track.position(at:10000,duration:40000) == 40000)
        }
    }
    @Test func denseTicksCombineVisuallyButSnappingKeepsTheExactTurn() {
        var words: [LibraryTranscriptItem] = []
        for i in 0..<127 {
            words.append(word("claire",Int64(i*1000),Int64(i*1000+300)))
            words.append(word("sam",Int64(i*1000+400),Int64(i*1000+600)))
        }
        let timeline = ListeningTimeline(turns:SpeakerTurn.grouping(words).filter { $0.speaker == "claire" })
        let track = ListeningTimeline.Track(minX:12,width:100)
        let marks = timeline.marks(duration:130000,track:track)
        #expect(timeline.starts.count == 127 && marks.count < 40)
        #expect(timeline.snapped(64000,duration:130000,track:track) == 64000)
        #expect(zip(marks,marks.dropFirst()).allSatisfy { $1-$0 >= 3 })
        #expect(ListeningTimeline().marks(duration:130000,track:track).isEmpty)
        #expect(ListeningTimeline().snapped(64000,duration:130000,track:track) == 64000)
    }
    @Test func emptyAndDegenerateGeometryNeverCreatesOrSnapsMarks() {
        let timeline = ListeningTimeline(turns:SpeakerTurn.grouping([word("ada",10000,10300)]))
        let zero = ListeningTimeline.Track(minX:12,width:0)
        #expect(timeline.marks(duration:40000,track:zero).isEmpty)
        #expect(timeline.snapped(9000,duration:40000,track:zero) == 9000)
        #expect(timeline.marks(duration:0,track:.init(minX:12,width:100)).isEmpty)
        #expect(zero.position(at:100,duration:40000) == 0)
    }
}
