// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
import Foundation
@testable import CassiniTranscription

/// D63 #1 (protocol conformance/multistream/fallback.json): the R71 tests pool every non-silent
/// track of one person, while the gocassini margin stays per track. Each case runs through
/// RecognitionFallback.decide, which the transcriber uses for its decision and provenance.
final class D63FallbackVectorsTests: XCTestCase {
    private struct Vectors: Decodable {
        struct Track: Decodable {
            let trackId: String, speaker: String, activeFrames: Int, vadWords: Int, fallbackWords: Int
            let silent: Bool?
        }
        struct Entry: Decodable, Equatable {
            let trackId: String, vadWords: Int, fallbackWords: Int, activeSeconds: Double, personActiveSeconds: Double, used: Bool
        }
        struct Expected: Decodable { let fires: [String:Bool]; let entries: [Entry] }
        struct Case: Decodable { let name: String; let tracks: [Track]; let expected: Expected }
        let cases: [Case]
    }
    static func vectors() throws -> URL {
        URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("browser-protocol/conformance/multistream/fallback.json")
    }
    func testEveryFallbackCaseDecidesAsTheVectorSays() throws {
        let vectors = try JSONDecoder().decode(Vectors.self,from:Data(contentsOf:Self.vectors()))
        XCTAssertEqual(vectors.cases.count,10)
        for item in vectors.cases {
            let decision = RecognitionFallback.decide(item.tracks.map {
                .init(trackId:$0.trackId,speaker:$0.speaker,activeFrames:$0.activeFrames,vadWords:$0.vadWords,fallbackWords:$0.fallbackWords,silent:$0.silent == true)
            })
            XCTAssertEqual(decision.fires,item.expected.fires,item.name)
            XCTAssertEqual(decision.entries.map {
                Vectors.Entry(trackId:$0.trackId,vadWords:$0.vadWords,fallbackWords:$0.fallbackWords,activeSeconds:$0.activeSeconds,
                              personActiveSeconds:$0.personActiveSeconds,used:$0.used)
            },item.expected.entries,item.name)
        }
    }
    /// The edge in whole frames, and mutants of the rule must fail the vectors.
    func testTheFrameEdgeAndThePerTrackMargin() {
        XCTAssertEqual(RecognitionFallback.minActiveFrames,469)
        XCTAssertTrue(RecognitionFallback.fires(activeFrames:469,vadWords:9))
        XCTAssertFalse(RecognitionFallback.fires(activeFrames:468,vadWords:0))
        XCTAssertFalse(RecognitionFallback.fires(activeFrames:10_000,vadWords:10))
        // Pooled per person: two halves fire together, two people never pool.
        let halves = RecognitionFallback.decide([.init(trackId:"a",speaker:"track-x",activeFrames:234,vadWords:0,fallbackWords:3),
                                                 .init(trackId:"b",speaker:"track-x",activeFrames:235,vadWords:0,fallbackWords:0)])
        XCTAssertEqual(halves.fires,["track-x":true])
        XCTAssertEqual(halves.entries.map(\.used),[true,false],"the margin stays per track")
        let two = RecognitionFallback.decide([.init(trackId:"a",speaker:"track-x",activeFrames:300,vadWords:0,fallbackWords:9),
                                              .init(trackId:"b",speaker:"track-y",activeFrames:300,vadWords:0,fallbackWords:9)])
        XCTAssertEqual(two.fires,["track-x":false,"track-y":false])
    }
}
