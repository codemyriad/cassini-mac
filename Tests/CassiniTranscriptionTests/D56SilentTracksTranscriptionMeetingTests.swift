// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
import Foundation
import CassiniLibrary
import CassiniRecording
import CassiniVAD
import CassiniWhistle
@testable import CassiniTranscription

/// D56 (R75): a track with fewer than 32 non-zero 32 ms frames is left out of recognition,
/// stays in the mixdown, and is listed in writingDown.silentTracks.
final class D56SilentTracksTranscriptionMeetingTests: XCTestCase {
    private func wave(_ url: URL, _ samples: [Int16]) throws {
        var data = Data()
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(36 + samples.count*2)); data.append(contentsOf: Array("WAVEfmt ".utf8)); u32(16)
        u16(1); u16(1); u32(16000); u32(32000); u16(2); u16(16)
        data.append(contentsOf: Array("data".utf8)); u32(UInt32(samples.count*2))
        for s in samples { u16(UInt16(bitPattern: s)) }
        try data.write(to: url)
    }
    /// `frames` 32 ms frames each holding one non-zero sample, in 60 s of 16 kHz audio.
    private func sparse(_ frames: Int) -> [Int16] {
        var samples = [Int16](repeating: 0, count: 16000 * 60)
        for f in 0..<frames { samples[f * 1024 + 7] = 1 }
        return samples
    }
    func testTheOneSecondNonZeroRule() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("D56Silent-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: root) }
        for (name, samples, silent) in [("zero", [Int16](repeating: 0, count: 16000 * 60), true), ("thirty-one", sparse(31), true),
                                        ("thirty-two", sparse(32), false), ("dc", [Int16](repeating: 3, count: 16000 * 2), false)] {
            let url = root.appendingPathComponent(name + ".wav"); try wave(url, samples)
            XCTAssertEqual(try MeetingTranscriber.isSilent(SegmentedAudio(url: url)), silent, name)
        }
    }
    private func runModel(_ samples: [Float]) -> WhistleTranscript {
        var words: [WhistleTranscript.Word] = [], start: Int?, lastSound = 0
        for (i,value) in (samples + [Float](repeating:0,count:801)).enumerated() {
            if value != 0 { if start == nil { start = i }; lastSound = i; continue }
            if let s = start, i - lastSound > 800 {
                words.append(.init(word:"w\(words.count)",start:Double(s)/16000,end:Double(lastSound + 1)/16000,probability:1)); start = nil
            }
        }
        return .init(text:words.map(\.word).joined(separator:" "),language:"en",words:words)
    }
    func testSilentTracksAreLeftOutOfRecognitionAndListed() throws {
        guard let assets = ProcessInfo.processInfo.environment["CASSINI_PIPELINE_ASSETS"] else { throw XCTSkip("Pinned offline VAD supplied by pipeline CI") }
        let detector = try SpeechDetector(assets:(try? VADAssets.forWorker(arguments:["--assets",assets])) ?? VADAssets.pinned(directory:URL(fileURLWithPath:assets)))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("D56SilentMeeting-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try RecordingSession(parent:root,title:"Silent tracks",source:"chromium")
        try session.transition(starting:[.init(id:"speech",label:"Guest",kind:"remote",sampleRate:16000,channels:1,sourceTrackId:"guest"),
                                         .init(id:"zeros",label:"Quiet",kind:"remote",sampleRate:16000,channels:1,sourceTrackId:"quiet"),
                                         .init(id:"blip",label:"Blip",kind:"remote",sampleRate:16000,channels:1,sourceTrackId:"blip")])
        let speech = try Data(contentsOf:XCTUnwrap(Bundle.module.url(forResource:"jfk",withExtension:"wav",subdirectory:"Goldens"))).dropFirst(44).prefix(160000)
        /// The recorder admits at most 262144 bytes per chunk.
        func append(_ id: String, _ pcm: Data) throws {
            for start in stride(from:0,to:pcm.count,by:80000) {
                try session.appendNative(id:id,pcm:pcm.subdata(in:start..<min(pcm.count,start + 80000)),offsetMs:Double(start / 2) / 16)
            }
        }
        try append("speech",Data(speech))
        try append("zeros",Data(count:320000))
        // 0.5 s of loud tone (under 1 s of sound) inside 10 s of zeros.
        var blip = [Int16](repeating:0,count:160000)
        for i in 16000..<24000 { blip[i] = Int16(8000 * sin(2 * Double.pi * 440 * Double(i) / 16000)) }
        try append("blip",blip.withUnsafeBytes { Data($0) })
        try session.finish()
        try MeetingTranscriber.run(directory:session.directory,detector:detector,model:"whistle",initialETA:0.15,recognize:runModel)
        let written = try XCTUnwrap(LibraryScanner(root:root).scan().meetings.first)
        XCTAssertFalse(written.transcriptItems.isEmpty)
        XCTAssertEqual(Set(written.transcriptItems.map(\.speaker)),["track-guest"],"silent tracks have no words")
        let stored = try JSONSerialization.jsonObject(with:Data(contentsOf:session.directory.appendingPathComponent("meeting.json"))) as? [String:Any]
        let writing = ((stored?["recordingDetails"] as? [String:Any])?["writingDown"] as? [String:Any]) ?? [:]
        XCTAssertEqual(writing["silentTracks"] as? [String],["zeros","blip"])
        let fallback = (writing["recognitionFallback"] as? [String:Any])?["tracks"] as? [[String:Any]] ?? []
        XCTAssertFalse(fallback.contains { ["zeros","blip"].contains($0["trackId"] as? String ?? "") })
        XCTAssertEqual(written.audioTracks.count,3,"they stay in the meeting and its mixdown")
    }
}
