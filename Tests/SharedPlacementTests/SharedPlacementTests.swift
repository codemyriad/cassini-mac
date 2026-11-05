// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
import Foundation
import AVFoundation
import CassiniKit
import CassiniLibrary
import CassiniVAD
import CassiniWhistle
@testable import CassiniTranscription
@testable import CassiniExport
@testable import CassiniPlayback

/// Shared test 9 (D55, protocol conformance/placement): every production consumer of a track's
/// placement lands every tone burst where D55 says, checked by the shared oracle
/// (placement.py check), never against the other app.
///
/// For the clean folders and each app mutant (make.py --mutant), this test drives Mac's own code:
/// - placement: TrackPlacement.frame on every placement.json case;
/// - rec16: the 16 kHz recognizer input (SegmentedAudio, the shared FIR) placed at the transcriber's
///   own start sample (MeetingTranscriber.placedStart);
/// - wordMs: the transcriber's word-time functions (sessionMs, clamped) with the pinned inputs;
/// - mix48: the 48 kHz export mix before encoding (MeetingFileExporter.inputs and .mix);
/// - playback: the production SessionComposition, its segments at each track's own rate, or
///   `refused` when it refuses the session (an unknown offset);
/// - offsetsAssumedZero: read back from what a real transcription and a real export wrote.
/// The streams go to scripts/placement-measure.py, which finds each burst with the shared detector
/// (placement.onset), writes the results file and runs placement.py check.
final class SharedPlacementTests: XCTestCase {
    static let repository = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let placement = repository.appendingPathComponent("browser-protocol/conformance/placement")
    struct Golden: Decodable {
        struct Session: Decodable { struct Track: Decodable { let id: String; let burstsMs: [Int] }; let id: String; let tracks: [Track] }
        struct Mutant: Decodable { let name: String }
        let sessions: [Session]; let mutants: [Mutant]
    }
    struct Case: Decodable { let ms: Double; let rate: Int; let frame: Int64 }
    static func golden() throws -> Golden {
        try JSONDecoder().decode(Golden.self,from:Data(contentsOf:placement.appendingPathComponent("bursts.json")))
    }

    func testCleanFolders() async throws { try await measure(nil) }
    func testMutantASystemLate() async throws { try await measure("a-system-late") }
    func testMutantBMic25ms() async throws { try await measure("b-mic-25ms") }
    func testMutantCSystemKnown() async throws { try await measure("c-system-known") }
    /// Every mutant in bursts.json is measured by one of the tests above.
    func testEveryMutantIsMeasured() throws {
        XCTAssertEqual(Set(try Self.golden().mutants.map(\.name)),["a-system-late","b-mic-25ms","c-system-known"])
    }

    private func assets() throws -> (SpeechDetector,OpusAssets) {
        let environment = ProcessInfo.processInfo.environment
        guard let vad = environment["CASSINI_PIPELINE_ASSETS"] else { throw XCTSkip("Pinned offline VAD supplied by CI (CASSINI_PIPELINE_ASSETS)") }
        guard let opus = environment["CASSINI_OPUS_ASSETS"] else { throw XCTSkip("Pinned Opus assets supplied by CI (CASSINI_OPUS_ASSETS)") }
        let detector = try SpeechDetector(assets:(try? VADAssets.forWorker(arguments:["--assets",vad])) ?? VADAssets.pinned(directory:URL(fileURLWithPath:vad)))
        let directory = URL(fileURLWithPath:opus)
        let hashes = try JSONDecoder().decode([String:String].self,from:Data(contentsOf:directory.appendingPathComponent("unsigned-sha256.json")))
        return (detector,try .builtForTests(directory:directory,expectedBinarySHA256:XCTUnwrap(hashes["libopus.0.dylib"])))
    }
    private func run(_ arguments: [String]) throws -> (Int32,String) {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath:"/usr/bin/env")
        process.arguments = ["python3","-I"] + arguments
        process.standardOutput = pipe; process.standardError = pipe
        try process.run()
        let output = String(decoding:pipe.fileHandleForReading.readDataToEndOfFile(),as:UTF8.self)
        process.waitUntilExit()
        return (process.terminationStatus,output)
    }
    private func write(_ samples: [Float], to url: URL) throws {
        try samples.withUnsafeBufferPointer { Data(buffer:$0) }.write(to:url)
    }
    private func key(_ meeting: LibraryMeeting, _ track: LibraryAudioTrack) -> String {
        meeting.id.uuidString.lowercased() + "/" + (track.sourceID ?? "")
    }

    private func measure(_ mutant: String?) async throws {
        let (detector,opus) = try assets()
        let golden = try Self.golden()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SharedPlacement-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let library = root.appendingPathComponent("library"), streams = root.appendingPathComponent("streams")
        try FileManager.default.createDirectory(at:streams,withIntermediateDirectories:true)
        let made = try run([Self.placement.appendingPathComponent("make.py").path] + (mutant.map { ["--mutant",$0] } ?? []) + [library.path])
        XCTAssertEqual(made.0,0,made.1)

        var manifest: [String:Any] = ["mutant":mutant ?? NSNull(),"golden":Self.placement.path,"app":"macos",
                                      "protocolCommit":try String(contentsOf:Self.repository.appendingPathComponent("browser-protocol/PINNED_COMMIT"),encoding:.utf8).trimmingCharacters(in:.whitespacesAndNewlines)]
        // placement: the one placement function on every literal case.
        struct Cases: Decodable { let cases: [Case] }
        let cases = try JSONDecoder().decode(Cases.self,from:Data(contentsOf:Self.placement.appendingPathComponent("placement.json"))).cases
        manifest["placement"] = cases.map { [$0.ms,$0.rate,TrackPlacement.frame(ms:$0.ms,rate:$0.rate)] as [Any] }

        var rec16: [String:String] = [:], wordMs: [String:[Int64]] = [:], mix48: [String:String] = [:]
        var playback: [String:Any] = [:], flags: [String:[String:Bool]] = [:]
        let meetings = try LibraryScanner(root:library).scan().meetings
        XCTAssertEqual(meetings.count,golden.sessions.count)
        for meeting in meetings {
            let session = meeting.id.uuidString.lowercased()
            let bursts = try XCTUnwrap(golden.sessions.first { $0.id == session })
            for track in meeting.audioTracks {
                let name = key(meeting,track)
                // rec16: the recognizer's 16 kHz input, at the transcriber's own start sample.
                let start = MeetingTranscriber.placedStart(offsetMs:track.startOffsetMs)
                let audio = try SegmentedAudio(url:track.url)
                let samples = try audio.samples(.init(startSample:0,endSample:audio.sampleCount,reason:"placement"))
                let file = streams.appendingPathComponent(name.replacingOccurrences(of:"/",with:"_") + ".rec16.f32")
                try write([Float](repeating:0,count:start) + samples,to:file)
                rec16[name] = file.path
                // wordMs: a segment starting at the burst's local 16 kHz sample, with a word at 0 s in it.
                let local = try XCTUnwrap(bursts.tracks.first { $0.id == track.sourceID }).burstsMs
                wordMs[name] = try local.map { t in
                    let word = WhistleTranscript.Word(word:"w",start:0,end:0.1,probability:1)
                    return try XCTUnwrap(MeetingTranscriber.clamped([word],startMs:MeetingTranscriber.sessionMs(startSample:start,local:16 * t),lengthMs:1000).first).startMs
                }
            }
            // mix48: the export mix before encoding.
            var mixed: [Float] = []
            try MeetingFileExporter.mix(inputs:MeetingFileExporter.inputs(meeting)) { mixed += $0 }
            let mixFile = streams.appendingPathComponent(session + ".mix48.f32")
            try write(mixed,to:mixFile); mix48[session] = mixFile.path
            // playback: the production composition, at each track's own rate.
            do {
                let timeline = try await SessionComposition.make(tracks:meeting.audioTracks,ownership:OthersOwnership(events:meeting.captureEvents))
                let composed = try await timeline.asset.loadTracks(withMediaType:.audio)
                XCTAssertEqual(composed.count,meeting.audioTracks.count,"one composition track per stored track")
                for (track,output) in zip(meeting.audioTracks,composed) {
                    let rate = try XCTUnwrap(track.sampleRate)
                    var stream: [Float] = []
                    for segment in output.segments where !segment.isEmpty {
                        let at = Int(CMTimeConvertScale(segment.timeMapping.target.start,timescale:Int32(rate),method:.roundHalfAwayFromZero).value)
                        let from = Int(CMTimeConvertScale(segment.timeMapping.source.start,timescale:Int32(rate),method:.roundHalfAwayFromZero).value)
                        let count = Int(CMTimeConvertScale(segment.timeMapping.source.duration,timescale:Int32(rate),method:.roundHalfAwayFromZero).value)
                        let source = try XCTUnwrap(segment.sourceURL)
                        let frames = try Self.mono(source,from:from,count:count)
                        if stream.count < at + frames.count { stream += [Float](repeating:0,count:at + frames.count - stream.count) }
                        for (i,value) in frames.enumerated() { stream[at + i] += value }
                    }
                    let file = streams.appendingPathComponent(key(meeting,track).replacingOccurrences(of:"/",with:"_") + ".playback.f32")
                    try write(stream,to:file)
                    playback[key(meeting,track)] = ["rate":rate,"stream":file.path]
                }
            } catch SessionComposition.Failure.unknownOffset {
                for track in meeting.audioTracks { playback[key(meeting,track)] = "refused" }
            }
            // offsetsAssumedZero, read back from what transcription and export wrote.
            try MeetingTranscriber.run(directory:meeting.folder,detector:detector,model:"whistle",initialETA:0.15) { _ in
                .init(text:"",language:"en",words:[])
            }
            let stored = try JSONSerialization.jsonObject(with:Data(contentsOf:meeting.folder.appendingPathComponent("meeting.json"))) as? [String:Any]
            let writing = (stored?["recordingDetails"] as? [String:Any])?["writingDown"] as? [String:Any]
            let reread = try XCTUnwrap(LibraryScanner(root:library).scan().meetings.first { $0.id == meeting.id })
            let artifact = try MeetingFileExporter.cassini(reread,assets:opus)
            let exported = try CassiniReader.read(contentsOf:artifact.url)
            flags[session] = ["transcript":writing?["offsetsAssumedZero"] as? Bool == true,
                              "export":exported.manifest?.raw["x"]?["gocassini.com"]?["recovery"]?["offsetsAssumedZero"] == .bool(true)]
        }
        manifest["rec16"] = rec16; manifest["wordMs"] = wordMs; manifest["mix48"] = mix48
        manifest["playback"] = playback; manifest["offsetsAssumedZero"] = flags
        let manifestFile = root.appendingPathComponent("manifest.json"), results = root.appendingPathComponent("results.json")
        try JSONSerialization.data(withJSONObject:manifest,options:[.sortedKeys]).write(to:manifestFile)
        let checked = try run([Self.repository.appendingPathComponent("scripts/placement-measure.py").path,manifestFile.path,results.path])
        if let report = ProcessInfo.processInfo.environment["CASSINI_PLACEMENT_REPORT_DIR"] {
            let directory = URL(fileURLWithPath:report)
            try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
            let name = mutant ?? "clean"
            try? FileManager.default.removeItem(at:directory.appendingPathComponent(name + ".json"))
            try? FileManager.default.copyItem(at:results,to:directory.appendingPathComponent(name + ".json"))
        }
        XCTAssertEqual(checked.0,0,"placement.py check \(mutant.map { "--mutant " + $0 } ?? ""):\n" + checked.1)
    }
    /// A file's frames at its own rate, channels averaged to mono (playback never resamples them).
    static func mono(_ url: URL, from: Int, count: Int) throws -> [Float] {
        let file = try AVAudioFile(forReading:url,commonFormat:.pcmFormatFloat32,interleaved:false)
        file.framePosition = AVAudioFramePosition(from)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat:file.processingFormat,frameCapacity:AVAudioFrameCount(count)))
        try file.read(into:buffer,frameCount:AVAudioFrameCount(count))
        let channels = Int(file.processingFormat.channelCount), frames = Int(buffer.frameLength)
        let data = try XCTUnwrap(buffer.floatChannelData)
        return (0..<frames).map { i in (0..<channels).reduce(Float(0)) { $0 + data[$1][i] } / Float(channels) }
    }
}
