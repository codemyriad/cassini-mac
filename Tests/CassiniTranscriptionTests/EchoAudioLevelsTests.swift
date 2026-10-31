// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import CryptoKit
import XCTest
@testable import CassiniTranscription

final class EchoAudioLevelsTests: XCTestCase {
    private struct Suite: Decodable { let cases: [Case] }
    private struct Case: Decodable { let id: String; let words: [Word] }
    private struct Word: Decodable {
        let track: String; let startMs: Int64; let endMs: Int64
        let rmsDbfs: Double; let otherWindowRmsDbfs: [String:Double]?
    }
    func testActualRawPCMMatchesAllFrozenWordAndWindowLevels() throws {
        let fixtures = URL(fileURLWithPath:#filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/Echo")
        let suite = try JSONDecoder().decode(Suite.self,from:Data(contentsOf:fixtures.appendingPathComponent("echo-vectors.json")))
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("CassiniEchoLevels-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:folder) }
        var assertions = 0
        for (index,sample) in suite.cases.prefix(2).enumerated() {
            let recording = fixtures.appendingPathComponent("Recordings/Recording-b1eed000-0000-4000-8000-00000000000\(index+1)")
            var streams: [String:FileHandle] = [:], counts: [String:Int] = [:]
            defer { for stream in streams.values { try? stream.close() } }
            for (track,name) in [("mic","microphone"),("system","system")] {
                let raw = try Data(contentsOf:recording.appendingPathComponent("track-"+name+".wav")).dropFirst(44)
                let samples = raw.withUnsafeBytes { bytes in
                    stride(from:0,to:raw.count,by:2).map { Float(Int16(littleEndian:bytes.loadUnaligned(fromByteOffset:$0,as:Int16.self)))/32768 }
                }
                let scratch = folder.appendingPathComponent("\(index)-\(track).f32")
                try samples.withUnsafeBytes { try Data($0).write(to:scratch) }
                streams[track] = try FileHandle(forReadingFrom:scratch); counts[track] = samples.count
            }
            for word in sample.words {
                let level = try EchoAudioLevels.measure(stream:XCTUnwrap(streams[word.track]),sampleCount:XCTUnwrap(counts[word.track]),from:word.startMs,to:word.endMs,offsetMs:0)
                XCTAssertEqual(try XCTUnwrap(level),word.rmsDbfs,accuracy:1e-7,sample.id); assertions += 1
                for (other,expected) in word.otherWindowRmsDbfs ?? [:] {
                    let level = try EchoAudioLevels.measure(stream:XCTUnwrap(streams[other]),sampleCount:XCTUnwrap(counts[other]),from:max(0,word.startMs-600),to:word.endMs,offsetMs:0)
                    XCTAssertEqual(try XCTUnwrap(level),expected,accuracy:1e-7,sample.id); assertions += 1
                }
            }
        }
        XCTAssertEqual(assertions,422)
    }
    func testOffsetClippingSilenceAndMissingWindows() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("CassiniEchoClip-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:file) }
        let samples = Array(repeating:Float(0.25),count:16000)
        try samples.withUnsafeBytes { try Data($0).write(to:file) }
        let stream = try FileHandle(forReadingFrom:file); defer { try? stream.close() }
        let level = try EchoAudioLevels.measure(stream:stream,sampleCount:16000,from:900,to:1600,offsetMs:1000)
        XCTAssertEqual(try XCTUnwrap(level),20*log10(0.25),accuracy:1e-10)
        XCTAssertNil(try EchoAudioLevels.measure(stream:stream,sampleCount:16000,from:100,to:200,offsetMs:1000))
        XCTAssertNil(try EchoAudioLevels.measure(stream:stream,sampleCount:16000,from:1200,to:1200,offsetMs:1000))
        XCTAssertNil(try EchoAudioLevels.measure(stream:stream,sampleCount:16000,from:3000,to:4000,offsetMs:1000))
    }
}
