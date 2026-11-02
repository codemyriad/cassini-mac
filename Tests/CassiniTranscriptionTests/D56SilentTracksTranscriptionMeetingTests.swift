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
    private func wave(_ url: URL, _ samples: [Int16], rate: Int = 16000, channels: Int = 1) throws {
        var data = Data()
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(36 + samples.count*2)); data.append(contentsOf: Array("WAVEfmt ".utf8)); u32(16)
        u16(1); u16(UInt16(channels)); u32(UInt32(rate)); u32(UInt32(rate * channels * 2)); u16(UInt16(channels * 2)); u16(16)
        data.append(contentsOf: Array("data".utf8)); u32(UInt32(samples.count*2))
        for s in samples { u16(UInt16(bitPattern: s)) }
        try data.write(to: url)
    }
    /// `frames` native 32 ms frames each holding one non-zero sample, in `seconds` of audio.
    private func sparse(_ frames: Int, rate: Int = 16000, seconds: Int = 60) -> [Int16] {
        let frame = rate * 32 / 1000
        var samples = [Int16](repeating: 0, count: rate * seconds)
        for f in 0..<frames { samples[f * 2 * frame + 7] = 1 }
        return samples
    }
    /// D57 (GNOME R76): native, non-overlapping floor(rate × 32 / 1000)-sample frames from the
    /// file's start, partial tail dropped, any channel != 0 (DC counts), fewer than 32 is silent.
    func testGnomeSilentTrackGeometry() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("D56Silent-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: root) }
        // 32 frames of sound, but the last one only in the trailing partial frame.
        var tail = sparse(31, seconds: 10); tail += [Int16](repeating: 0, count: 100); tail[tail.count - 3] = 9
        // Stereo: the left channel is all zeros, the right channel has 32 frames of sound.
        var stereo = [Int16](repeating: 0, count: 16000 * 10 * 2)
        for f in 0..<32 { stereo[(f * 2 * 512 + 5) * 2 + 1] = 4 }
        let cases: [(String, [Int16], Int, Int, Bool)] = [
            ("zero", [Int16](repeating: 0, count: 16000 * 60), 16000, 1, true),
            ("thirty-one", sparse(31), 16000, 1, true),
            ("thirty-two", sparse(32), 16000, 1, false),
            ("dc", [Int16](repeating: 3, count: 16000 * 2), 16000, 1, false),
            ("partial-tail-never-counts", tail, 16000, 1, true),
            ("any-channel", stereo, 16000, 2, false),
            ("48k-frame-1536", sparse(32, rate: 48000, seconds: 5), 48000, 1, false),
            ("48k-thirty-one", sparse(31, rate: 48000, seconds: 5), 48000, 1, true),
            ("44k1-frame-1411", sparse(32, rate: 44100, seconds: 5), 44100, 1, false),
        ]
        for (name, samples, rate, channels, silent) in cases {
            let url = root.appendingPathComponent(name + ".wav"); try wave(url, samples, rate: rate, channels: channels)
            XCTAssertEqual(MeetingTranscriber.isSilent(wav: url), silent, name)
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
