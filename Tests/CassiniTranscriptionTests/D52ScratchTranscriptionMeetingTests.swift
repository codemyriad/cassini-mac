// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
import Foundation
import CassiniLibrary
import CassiniRecording
import CassiniWhistle
@testable import CassiniTranscription

/// D52 M15: temporary disk does not grow with the number of spans. Planning and
/// recognition each keep one track's 16 kHz scratch at a time.
final class D52ScratchTranscriptionMeetingTests: XCTestCase {
    private func scratchCount() -> Int {
        let prefix = "CassiniSpeech-\(getpid())-"
        return ((try? FileManager.default.contentsOfDirectory(atPath:FileManager.default.temporaryDirectory.path)) ?? []).filter { $0.hasPrefix(prefix) }.count
    }
    func testManySpansNeverHoldMoreThanOneScratch() throws {
        guard let assets = ProcessInfo.processInfo.environment["CASSINI_PIPELINE_ASSETS"] else { throw XCTSkip("Pinned offline VAD supplied by pipeline CI") }
        let detector = try SpeechDetector(assets:(try? VADAssets.forWorker(arguments:["--assets",assets])) ?? VADAssets.pinned(directory:URL(fileURLWithPath:assets)))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("D52Scratch-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let session = try RecordingSession(parent:root,title:"Many spans",source:"chromium")
        // Real speech (the bundled JFK golden, 16 kHz mono) so the VAD plans segments on every track.
        let speech = try Data(contentsOf:XCTUnwrap(Bundle.module.url(forResource:"jfk",withExtension:"wav",subdirectory:"Goldens"))).dropFirst(44)
        let pcm = Data(speech.prefix(160000))
        var sources: [RecordingSource] = [.init(id:"mic",label:"Mic",kind:"microphone",sampleRate:16000,channels:1),
                                          .init(id:"system",label:"System",kind:"system",sampleRate:16000,channels:1)]
        sources += (0..<12).map { .init(id:"r\($0)",label:"Guest \($0)",kind:"remote",sampleRate:16000,channels:1,sourceTrackId:"guest-\($0)") }
        try session.transition(starting:sources)
        for source in sources { try session.appendNative(id:source.id,pcm:pcm,offsetMs:0) }
        try session.finish()
        let before = scratchCount()
        var peak = 0, calls = 0
        try MeetingTranscriber.run(directory:session.directory,detector:detector,model:"whistle",initialETA:0.15,recognize:{ _ in
            calls += 1; peak = max(peak,self.scratchCount() - before)
            return .init(text:"",language:"en",words:[])
        })
        XCTAssertGreaterThanOrEqual(calls,sources.count,"every span was recognised")
        XCTAssertEqual(peak,1,"one track's scratch at a time, across \(sources.count) spans")
        XCTAssertEqual(scratchCount(),before,"every scratch is released")
        _ = calls
    }
}
