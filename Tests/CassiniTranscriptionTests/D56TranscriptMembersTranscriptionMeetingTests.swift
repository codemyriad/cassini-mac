// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
import Foundation
import CassiniKit
import CassiniLibrary
import CassiniRecording
import CassiniVAD
import CassiniWhistle
@testable import CassiniTranscription

/// D47/D56: a write-down edits the stored transcript object, so members this app does not
/// know (on transcript and on speakers) survive every progress write and the final one.
final class D56TranscriptMembersTranscriptionMeetingTests: XCTestCase {
    func testUnknownTranscriptAndSpeakerMembersSurviveAWriteDown() throws {
        guard let assets = ProcessInfo.processInfo.environment["CASSINI_PIPELINE_ASSETS"] else { throw XCTSkip("Pinned offline VAD supplied by pipeline CI") }
        let detector = try SpeechDetector(assets:(try? VADAssets.forWorker(arguments:["--assets",assets])) ?? VADAssets.pinned(directory:URL(fileURLWithPath:assets)))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("D56Transcript-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let session = try RecordingSession(parent:root,title:"Members",source:"macos")
        try session.addTrack(id:"mic",label:"Mic",kind:"microphone",sampleRate:16000,channels:1)
        let pcm = try Data(contentsOf:XCTUnwrap(Bundle.module.url(forResource:"jfk",withExtension:"wav",subdirectory:"Goldens"))).dropFirst(44)
        try session.appendNative(id:"mic",pcm:Data(pcm.prefix(160000)),offsetMs:0)
        try session.finish()
        try MeetingMetadataWriter(directory:session.directory,id:session.manifest.id).transaction { metadata in
            var transcript = metadata["transcript"] as? [String:Any] ?? [:]
            transcript["futureFlag"] = ["kept":"yes"]; metadata["transcript"] = transcript
        }
        // One word per call is enough: this checks metadata, not recognition.
        try MeetingTranscriber.run(directory:session.directory,detector:detector,model:"whistle",initialETA:0.15) { samples in
            .init(text:"w",language:"en",words:[.init(word:"w",start:0,end:Double(samples.count)/16000,probability:1)])
        }
        let stored = try JSONParser.parse(Data(contentsOf:session.directory.appendingPathComponent("meeting.json")))
        XCTAssertEqual(stored["transcript"]?["status"]?.string,"done")
        XCTAssertEqual(try stored["transcript"]?["futureFlag"]?.encoded(),Data(#"{"kept":"yes"}"#.utf8))
    }
}
