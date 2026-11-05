// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
import Foundation
import CassiniLibrary
@testable import CassiniTranscription

/// D63 #3 (protocol conformance/multistream/writedown.json, `keep`): a word is written only when
/// its midpoint lies in its track's present-or-unknown time with ownership, compared in 16 kHz
/// session samples from the D55 placement. Each synthetic track goes through the transcriber's
/// own placement, presence, ownership and write rule.
final class D63WritedownVectorsTests: XCTestCase {
    struct Gap: Decodable { let atMs: Double; let durationMs: Double?; let frames: UInt64?; let kind: String }
    struct Track: Decodable { let startOffsetMs: Double; let sampleRate: Int; let frames: Int; let gaps: [Gap]? }
    struct Word: Decodable { let ms: [Int64]; let keep: Bool }
    struct Keep: Decodable { let name: String; let track: Track; let ownership: [[Double]]?; let words: [Word] }
    struct TurnCase: Decodable { let name: String; let gaps: [Gap]?; let words: [[Int64]]; let turns: [Int] }
    struct Vectors: Decodable { let keep: [Keep]; let turns: [TurnCase] }
    static func vectors() throws -> Vectors {
        let url = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("browser-protocol/conformance/multistream/writedown.json")
        return try JSONDecoder().decode(Vectors.self,from:Data(contentsOf:url))
    }
    /// What the transcriber keeps for one stored track: its D55 placement and its kept ranges.
    static func kept(_ track: Track, ownership: [[Double]]?) -> (startSample: Int, kept: [Range<Int>]) {
        let startSample = Int(TrackPlacement.frame(ms:track.startOffsetMs,rate:16000))
        let offset = Double(startSample) / 16, sampleCount = track.frames * 16000 / track.sampleRate
        let gaps = MeetingTranscriber.presenceGaps(track.gaps?.map { .init(atMs:$0.atMs,durationMs:$0.durationMs,frames:$0.frames,kind:$0.kind) },sampleRate:track.sampleRate)
        let mask = ownership?.map { (start:$0[0],end:$0[1]) }
        guard let owned = MeetingTranscriber.ownedWindows(offsetMs:offset,sampleCount:sampleCount,gaps:gaps,mask:mask) else { return (startSample,[0..<sampleCount]) }
        return (startSample,MeetingTranscriber.keptRanges(owned,offsetMs:offset,sampleCount:sampleCount))
    }
    func testEveryKeepCaseIsWrittenAsTheVectorSays() throws {
        let vectors = try Self.vectors()
        XCTAssertEqual(vectors.keep.count,7)
        for item in vectors.keep {
            let (startSample,kept) = Self.kept(item.track,ownership:item.ownership)
            for word in item.words {
                XCTAssertEqual(MeetingTranscriber.writes(startMs:word.ms[0],endMs:word.ms[1],kept:kept,startSample:startSample),word.keep,"\(item.name) \(word.ms)")
            }
        }
    }
    /// A closed range must fail the vectors. (A midpoint rounded to whole ms is caught by the
    /// corpus's a-long word midpoints, in D52CorpusTests.)
    func testAClosedRangeFailsTheVectors() throws {
        let vectors = try Self.vectors()
        func agrees(_ rule: (Int64,Int64,[Range<Int>],Int) -> Bool) -> Bool {
            vectors.keep.allSatisfy { item in
                let (startSample,kept) = Self.kept(item.track,ownership:item.ownership)
                return item.words.allSatisfy { rule($0.ms[0],$0.ms[1],kept,startSample) == $0.keep }
            }
        }
        XCTAssertTrue(agrees { MeetingTranscriber.writes(startMs:$0,endMs:$1,kept:$2,startSample:$3) })
        XCTAssertFalse(agrees { a,b,kept,start in
            let m = 8 * (Int(a) + Int(b))
            return kept.contains { start + $0.lowerBound <= m && m <= start + $0.upperBound }
        },"a closed range")
    }
}
