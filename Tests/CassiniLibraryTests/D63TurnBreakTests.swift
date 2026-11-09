// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
import Foundation
@testable import CassiniLibrary

/// D63 #2 (protocol conformance/multistream/writedown.json, `turns`): a turn never spans a gap
/// range of its own track. Each case's gaps go on a stored track of one remote, the speaker's gap
/// ranges come from SpeakerGapRanges as readers derive them, and every grouper is checked: the
/// meeting view's turns (with the 400 ms seam rejoin, also used by Search), the coalesced turns of
/// the Library excerpt, and Markdown export.
final class D63TurnBreakTests: XCTestCase {
    struct Gap: Decodable { let atMs: Double; let durationMs: Double?; let frames: UInt64?; let kind: String }
    struct TurnCase: Decodable { let name: String; let gaps: [Gap]?; let words: [[Int64]]; let turns: [Int] }
    struct Vectors: Decodable { let turns: [TurnCase] }
    static func vectors() throws -> Vectors {
        let url = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("browser-protocol/conformance/multistream/writedown.json")
        return try JSONDecoder().decode(Vectors.self,from:Data(contentsOf:url))
    }
    /// One remote's stored track, at 48 kHz, holding the case's gaps; its speaker is track-x.
    static func ranges(_ gaps: [Gap]?) -> SpeakerGapRanges.Ranges {
        let track = LibraryAudioTrack(url:URL(fileURLWithPath:"/tmp/track-x.wav"),startOffsetMs:0,frameCount:48000*120,sourceID:"x",sourceKind:"remote",
                                      sourceTrackID:"x",sampleRate:48000,gaps:gaps?.map { .init(atMs:$0.atMs,durationMs:$0.durationMs,frames:$0.frames,kind:$0.kind) })
        return SpeakerGapRanges.of([track],received:false)
    }
    static func items(_ words: [[Int64]]) -> [LibraryTranscriptItem] {
        words.enumerated().map { .init(speaker:"track-x",startMs:$0.element[0],endMs:$0.element[1],text:"w\($0.offset)") }
    }
    func testEveryTurnCaseSplitsAsTheVectorSaysInEveryGrouper() throws {
        let vectors = try Self.vectors()
        XCTAssertEqual(vectors.turns.count,8)
        for item in vectors.turns {
            let gaps = Self.ranges(item.gaps), words = Self.items(item.words)
            // D84 adds viewer readable paragraphs; D63's explicit source-gap rule stays unchanged.
            // This one no-gap long pause is now two readable rows, while the D70 listening run remains one.
            let readable = item.name == "a-long-pause-without-a-gap-range-joins" ? [1,2] : item.turns
            XCTAssertEqual(MeetingPresentation.turns(words,gaps:gaps).map(\.items.count),readable,"\(item.name): meeting turns")
            XCTAssertEqual(LibraryTranscriptTurn.coalescing(words,gaps:gaps).map { $0.text.split(separator:" ").count },readable,"\(item.name): coalesced turns")
            let markdown = MeetingMarkdown.render(title:"T",start:nil,durationMs:nil,timeZone:TimeZone(secondsFromGMT:0)!,names:["track-x":"X"],items:words,notes:[],gaps:gaps,language:.en)
            XCTAssertEqual(markdown.components(separatedBy:"**X** · ").count - 1,readable.count,"\(item.name): Markdown turns")
        }
    }
    /// The seam rejoin never joins across a gap range, even with another speaker in between.
    func testTheSeamRejoinNeverJoinsAcrossAGap() {
        let gaps = Self.ranges([.init(atMs:10000,durationMs:300,frames:14400,kind:"jump")])
        let words: [LibraryTranscriptItem] = [.init(speaker:"track-x",startMs:9000,endMs:9950,text:"one"),
                                              .init(speaker:"track-y",startMs:9900,endMs:10100,text:"yes"),
                                              .init(speaker:"track-x",startMs:10300,endMs:10600,text:"two")]
        XCTAssertEqual(MeetingPresentation.turns(words,gaps:gaps).filter { $0.speaker == "track-x" }.count,2)
        XCTAssertEqual(MeetingPresentation.turns(words).filter { $0.speaker == "track-x" }.count,1,"without the gap, the seam rejoins")
    }
    /// Mutants of the rule must fail the vectors: splitting on word edges, or on an overflow marker.
    /// (A gap range closed at its end is caught by the corpus turn cases, in D52CorpusTests.)
    func testMutantsFailTheVectors() throws {
        let vectors = try Self.vectors()
        func agrees(_ split: (LibraryTranscriptItem,LibraryTranscriptItem,[Range<Int64>],[Gap]?) -> Bool) -> Bool {
            vectors.turns.allSatisfy { item in
                let words = Self.items(item.words), own = Self.ranges(item.gaps)["track-x"] ?? []
                var sizes: [Int] = []
                for (index,word) in words.enumerated() {
                    if index > 0 && !split(words[index-1],word,own,item.gaps) { sizes[sizes.count-1] += 1 } else { sizes.append(1) }
                }
                return sizes == item.turns
            }
        }
        XCTAssertTrue(agrees { a,b,_,gaps in SpeakerGapRanges.splits(a,b,Self.ranges(gaps)) })
        XCTAssertFalse(agrees { a,b,own,_ in own.contains { $0.lowerBound < 16 * b.startMs && 16 * a.endMs < $0.upperBound } },"word edges")
        XCTAssertFalse(agrees { a,b,own,gaps in
            let overflow = (gaps ?? []).filter { $0.kind == "overflow" }.map { Int64(16 * $0.atMs) }
            return SpeakerGapRanges.splits(a,b,["track-x":own]) || overflow.contains { min(16*(a.startMs+a.endMs)/2,16*(b.startMs+b.endMs)/2) < $0 && $0 <= max(16*(a.startMs+a.endMs)/2,16*(b.startMs+b.endMs)/2) }
        },"an overflow marker")
    }
}
