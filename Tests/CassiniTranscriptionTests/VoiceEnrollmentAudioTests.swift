// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
import CassiniLibrary
import CassiniRecording
@testable import CassiniTranscription

struct VoiceEnrollmentAudioTests {
    private func fixture() throws -> (URL,LibraryMeeting) {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let session=try RecordingSession(parent:root,title:"Voices",source:"chromium")
        try session.addTrack(id:"guest",label:"Guest",kind:"remote",sampleRate:16000,channels:1)
        // Constant PCM makes the selected source and range easy to identify.
        try session.append(id:"guest",pcm:Data(repeating:32,count:192000),offsetMs:2000)
        try session.finish()
        var meeting=try #require(LibraryScanner(root:root).meeting(at:session.directory))
        meeting.transcriptItems=[.init(speaker:"track-guest",startMs:2000,endMs:8000,text:"Speech")]
        return (root,meeting)
    }
    @Test func offsetsAndSourceMappingSelectOnlyTheNamedRemoteTrack() throws {
        let (root,meeting)=try fixture();defer {try? FileManager.default.removeItem(at:root)}
        let selected=try #require(try VoiceEnrollmentAudio.prepare(meeting,speaker:"track-guest"))
        #expect(selected.clip.startMs == 2200 && selected.clip.endMs == 7800)
        #expect(selected.samples.count == 89600)
        #expect(selected.samples.allSatisfy { abs($0 - Float(0x2020)/32768) < 0.00001 })
        #expect(try VoiceEnrollmentAudio.prepare(meeting,speaker:"me") == nil)
        #expect(try VoiceEnrollmentAudio.prepare(meeting,speaker:"others") == nil)
        #expect(try VoiceEnrollmentAudio.prepare(meeting,speaker:"track-absent") == nil)
    }
    @Test func gapsExcludeContaminatedWindows() throws {
        let (root,original)=try fixture();defer {try? FileManager.default.removeItem(at:root)}
        var meeting=original
        let track=meeting.audioTracks[0]
        meeting.audioTracks=[.init(url:track.url,startOffsetMs:2000,frameCount:96000,sourceID:"guest",sourceKind:"remote",sampleRate:16000,
                                   gaps:[.init(atMs:1000,durationMs:nil,frames:16000,kind:"overflow")])]
        #expect(try VoiceEnrollmentAudio.prepare(meeting,speaker:"track-guest") == nil)
    }
    @Test func decodeWorkDoesNotScaleWithUnusedElevenHourTail() throws {
        let (root,original)=try fixture();defer {try? FileManager.default.removeItem(at:root)}
        let url=original.audioTracks[0].url
        var work:[Int]=[]
        // Physical sparse WAVs exercise the real decoder. Count decoded frames,
        // not elapsed wall time: both lengths must stop at the last selected range.
        for seconds in [60,11*60*60] {
            let file=try FileHandle(forWritingTo:url)
            try file.truncate(atOffset:UInt64(44+seconds*16000*2));try file.close()
            var meeting=original, frames=0
            meeting.audioTracks=[.init(url:url,startOffsetMs:2000,frameCount:UInt64(seconds*16000),sourceID:"guest",sourceKind:"remote",sampleRate:16000)]
            let selection=try #require(try VoiceEnrollmentAudio.prepare(meeting,speaker:"track-guest",decode:{ url,consume in
                try MeetingAudioDecoder.decode(url) { block,rate in frames += block.count;try consume(block,rate) }
            }))
            #expect(selection.samples.count == 89600)
            work.append(frames)
        }
        #expect(work[0] == work[1] && work[1] < 100000)
    }
}
