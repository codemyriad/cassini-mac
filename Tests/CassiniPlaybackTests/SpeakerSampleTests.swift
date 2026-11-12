// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import Testing
@testable import CassiniLibrary
@testable import CassiniPlayback

extension SessionPlaybackTests {
    private func sampleScene() -> (LibraryMeeting,SessionPlayback,SpanTransport,SpeakerSample) {
        let transport=SpanTransport()
        let audio=SessionPlayback(build:{_ in SessionTimeline(asset:AVMutableComposition(),storage:PlaybackStorage(),durationMs:30_000)},makeTransport:{_ in transport})
        var meeting=LibraryMeeting(id:UUID(),folder:URL(fileURLWithPath:"/tmp/d24-sample"),state:.init(),title:"Call",start:nil,durationMs:30_000,speakers:[],quote:nil,notes:[],audioFiles:[],issues:[])
        meeting.audioTracks=[.init(url:URL(fileURLWithPath:"/tmp/d24.wav"),startOffsetMs:0,frameCount:240_000,sampleRate:8000)]
        return (meeting,audio,transport,SpeakerSample(playback:audio))
    }
    @Test func sampleStopsAtTheActualBoundaryAndRestoresPaused() async throws {
        let (meeting,audio,fake,sample)=sampleScene();defer {audio.stop()}
        audio.seek(meeting,toMs:23_000)
        #expect(sample.play(meeting,range:1000..<20_000))
        await audio.preparation?.value;fake.sought()
        #expect(fake.boundary?.0==11_000 && audio.isPlaying && sample.active)
        fake.endedSpan()
        #expect(!sample.active && !audio.isPlaying && audio.positionMs==23_000)
        #expect(fake.seeks.last?.0==23_000 && fake.boundary==nil)
        fake.sought()
        #expect(!audio.isPlaying && fake.positionMs==23_000)
    }
    @Test func cancelledAndReplacedSamplesFenceOldCompletion() async throws {
        let (meeting,audio,fake,sample)=sampleScene();defer {audio.stop()}
        audio.seek(meeting,toMs:17_000)
        sample.play(meeting,range:1000..<3000);await audio.preparation?.value;fake.sought()
        let old=try #require(fake.boundary?.1)
        sample.play(meeting,range:5000..<6000);fake.sought()
        old()
        #expect(sample.active && fake.boundary?.0==6000 && audio.isPlaying)
        sample.cancel();fake.sought()
        #expect(!sample.active && !audio.isPlaying && fake.positionMs==17_000)
        old()
        #expect(fake.positionMs==17_000 && !audio.isPlaying)
    }
    @Test func sampleCancellationDuringPreparationCannotStartAudio() async {
        let (meeting,audio,fake,sample)=sampleScene();defer {audio.stop()}
        audio.seek(meeting,toMs:15_000)
        sample.play(meeting,range:1000..<2000);sample.cancel()
        await audio.preparation?.value;fake.sought()
        #expect(fake.plays==0 && !sample.active && !audio.isPlaying && fake.positionMs==15_000)
    }
}
