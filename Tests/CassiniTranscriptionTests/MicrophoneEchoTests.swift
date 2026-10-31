// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import CryptoKit
import XCTest
@testable import CassiniTranscription

final class MicrophoneEchoTests: XCTestCase {
    private struct Suite: Decodable { let cases: [Case] }
    private struct Case: Decodable { let id: String; let tracks: [Track]; let words: [Word]; let expectedEcho: [Bool] }
    private struct Track: Decodable { let id: String; let kind: String }
    private struct Word: Decodable {
        let track: String; let startMs: Int64; let endMs: Int64; let text: String
        let rmsDbfs: Double; let otherWindowRmsDbfs: [String:Double]?
    }
    func testEveryFrozenSharedEchoVector() throws {
        let file = URL(fileURLWithPath:#filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/Echo/echo-vectors.json")
        let data = try Data(contentsOf:file)
        XCTAssertEqual(SHA256.hash(data:data).map { String(format:"%02x",$0) }.joined(),"81805038e849a856783bd51c5965735f4d3f1246ac31eeb584050b7940365ad2")
        let suite = try JSONDecoder().decode(Suite.self,from:data)
        XCTAssertEqual(suite.cases.count,20); XCTAssertEqual(suite.cases.reduce(0) { $0+$1.words.count },311)
        for sample in suite.cases {
            let indices = Dictionary(uniqueKeysWithValues:sample.tracks.enumerated().map { ($0.element.id,$0.offset) })
            let mic = Set(sample.tracks.enumerated().filter { $0.element.kind == "microphone" }.map(\.offset))
            let others = Set(indices.values).subtracting(mic)
            let words = try sample.words.map { word in
                MicrophoneEcho.Word(track:try XCTUnwrap(indices[word.track]),startMs:word.startMs,endMs:word.endMs,text:word.text,rmsDbfs:word.rmsDbfs)
            }
            let actual = MicrophoneEcho.flags(words,microphones:mic,others:others) { index in
                (sample.words[index].otherWindowRmsDbfs ?? [:]).contains { track,level in
                    indices[track].map(others.contains) == true && sample.words[index].rmsDbfs <= level-6
                }
            }
            XCTAssertEqual(actual,sample.expectedEcho,sample.id)
        }
    }
    func testLargeCoincidentRepeatedWordsUseIndexedLevels() {
        let other = MicrophoneEcho.Word(track:1,startMs:0,endMs:100,text:"Same",rmsDbfs:-10)
        let mic = MicrophoneEcho.Word(track:0,startMs:300,endMs:400,text:"same",rmsDbfs:-20)
        let words = Array(repeating:other,count:10000)+Array(repeating:mic,count:10000)
        let flags = MicrophoneEcho.flags(words,microphones:[0],others:[1]) { _ in XCTFail("Direct matches need no sandwich measurement"); return false }
        XCTAssertTrue(flags.prefix(10000).allSatisfy { !$0 }); XCTAssertTrue(flags.suffix(10000).allSatisfy { $0 })
    }
    func testAbsentAndNonfiniteMeasurementsCannotSuppressWords() {
        let words = [
            MicrophoneEcho.Word(track:1,startMs:0,endMs:100,text:"yes",rmsDbfs:-10),
            .init(track:0,startMs:100,endMs:200,text:"yes",rmsDbfs:nil),
            .init(track:0,startMs:200,endMs:300,text:"yes",rmsDbfs:.nan)
        ]
        XCTAssertEqual(MicrophoneEcho.flags(words,microphones:[0],others:[1]) { _ in true },[false,false,false])
    }
    func testSandwichAnchorsNeverCrossPhysicalMicrophones() {
        let words: [MicrophoneEcho.Word] = [
            .init(track:2,startMs:0,endMs:100,text:"before",rmsDbfs:-10),
            .init(track:2,startMs:500,endMs:600,text:"after",rmsDbfs:-10),
            .init(track:0,startMs:300,endMs:400,text:"before",rmsDbfs:-22),
            .init(track:1,startMs:800,endMs:900,text:"after",rmsDbfs:-22),
            .init(track:0,startMs:500,endMs:600,text:"my own word",rmsDbfs:-22)]
        XCTAssertEqual(MicrophoneEcho.flags(words,microphones:[0,1],others:[2]) { _ in
            XCTFail("Two microphone sources cannot bracket each other's words"); return true
        },[false,false,true,true,false])
    }
}
