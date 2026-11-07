// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import Testing
@testable import CassiniLibrary
@testable import CassiniPlayback

@MainActor final class SpanTransport: SessionTransport {
    var onState: ((SessionTransportState) -> Void)?
    var onEnd: (() -> Void)?
    var onFailure: ((Error) -> Void)?
    var onPosition: ((Double) -> Void)?
    var positionMs = 0.0
    var plays = 0, pauses = 0, closes = 0
    var rate: Float = 1
    var seeks: [(Double,@MainActor @Sendable (Bool) -> Void)] = []
    var boundary: (Double,@MainActor @Sendable () -> Void)?
    var bounds: [Double] = []
    func play() { plays += 1 }
    func pause() { pauses += 1 }
    func rewind(_ completion: @escaping @MainActor @Sendable (Bool) -> Void) { seek(toMs:0,completion:completion) }
    func close() { closes += 1; boundary = nil }
    func seek(toMs: Double, completion: @escaping @MainActor @Sendable (Bool) -> Void) { seeks.append((toMs,completion)) }
    func setRate(_ rate: Float) { self.rate = rate }
    func setBoundary(atMs: Double, completion: @escaping @MainActor @Sendable () -> Void) {
        boundary = (atMs,completion); bounds.append(atMs)
    }
    func clearBoundary() { boundary = nil }
    func sought() {
        guard let request = seeks.last else { Issue.record("No transport seek was requested"); return }
        positionMs = request.0; request.1(true)
    }
    func endedSpan() {
        guard let request = boundary else { Issue.record("No transport boundary was installed"); return }
        positionMs = request.0; request.1()
    }
    func position(_ ms: Double) { positionMs = ms; onPosition?(ms) }
}

@MainActor private func scene(_ words: [LibraryTranscriptItem]? = nil) -> (LibraryMeeting,SessionPlayback,SpanTransport,ListenController) {
    let fake = SpanTransport()
    let audio = SessionPlayback(build:{ _ in
        SessionTimeline(asset:AVMutableComposition(),storage:PlaybackStorage(),durationMs:20_000)
    },makeTransport:{ _ in fake })
    var meeting = LibraryMeeting(id:UUID(),folder:URL(fileURLWithPath:"/tmp/d70-synthetic"),state:.init(),title:"Synthetic call",start:nil,
        durationMs:20_000,speakers:[],quote:nil,notes:[],audioFiles:[],issues:[])
    meeting.audioTracks = [.init(url:URL(fileURLWithPath:"/tmp/d70-synthetic.wav"),startOffsetMs:0,frameCount:160_000,sampleRate:8000)]
    let spans: [(String,Int64,Int64)] = [("cleo",500,900),("ben",1000,2500),("ada",3000,3300),("ben",4000,6000),
        ("ada",7000,7500),("ben",8000,8500),("ada",9000,9300),("ben",10000,10500),("ada",11000,11300),
        ("ben",12000,13000),("ada",14000,14500),("ben",15000,19000),("ada",19700,19900)]
    meeting.transcriptItems = words ?? spans.map { .init(speaker:$0.0,startMs:$0.1,endMs:$0.2,text:"Hello.") }
    let listen = ListenController(playback:audio); listen.setTurns(meeting.speakerTurns)
    return (meeting,audio,fake,listen)
}

// These share SessionPlayback.stopAll's process-wide owner with the original
// playback tests, so they belong to that same serialized suite (E1/D66).
extension SessionPlaybackTests {
    @Test func queuedEOFWithinOneAudioFrameCompletesTheOwnedSpan() async {
        let (meeting,audio,fake,_) = scene(); var ended = 0
        audio.play(meeting,fromMs:123,untilMs:423,onDone:{ ended += 1 })
        await audio.preparation?.value; fake.sought()
        fake.positionMs = 422.875 // One 8 kHz frame before the requested millisecond.
        fake.onEnd?()
        #expect(ended == 1 && audio.positionMs == 423 && !audio.isPlaying)
        audio.stop()
    }
    @Test func frozenListeningPreviewCreatesNoTransportOrPlayback() {
        let (_,audio,fake,listen) = scene()
        listen.preview("ada",index:100,finished:true)
        #expect(listen.active && listen.finished && listen.index == listen.count-1)
        #expect(audio.preparation == nil && !audio.isPlaying && fake.plays == 0 && fake.seeks.isEmpty)
        listen.stopPlayback()
        #expect(!listen.active && fake.plays == 0 && fake.closes == 0)
    }
    @Test func eofDistinguishesAnExplicitPauseFromANaturalBackendPause() async {
        let (meeting,audio,fake,listen) = scene()
        audio.toggle(meeting); await audio.preparation?.value
        fake.position(3200); audio.pause(); fake.onEnd?()
        #expect(audio.positionMs == 3200 && !audio.isPlaying)
        // A stale Stop from a cleared mode must not pause ordinary playback.
        audio.toggle(meeting); listen.stopPlayback()
        #expect(audio.isPlaying)
        fake.position(20000); fake.onState?(.paused); fake.onEnd?()
        #expect(audio.positionMs == 0 && fake.seeks.last?.0 == 0,"ordinary natural EOF still rewinds")
        audio.stop()
    }
    @Test func rowStopPausesInPlaceAndFencesQueuedEndWhilePreparingOrPlaying() async {
        for stopBeforePrepared in [true,false] {
            let (meeting,audio,fake,listen) = scene()
            #expect(listen.start("ada",in:meeting))
            if stopBeforePrepared { listen.stopPlayback() }
            await audio.preparation?.value; fake.sought()
            if !stopBeforePrepared {
                fake.position(3200)
                let stale = fake.boundary?.1
                listen.stopPlayback(); stale?()
                #expect(audio.positionMs == 3200 && fake.positionMs == 3200)
            }
            #expect(!audio.isPlaying && !listen.active && fake.boundary == nil)
            let plays = fake.plays, stoppedAt = audio.positionMs
            fake.onEnd?()
            #expect(fake.plays == plays && !audio.isPlaying)
            #expect(audio.positionMs == stoppedAt,"an EOF queued before Stop cannot rewind its paused position")
            audio.stop()
        }
    }
    @Test func overlappingChainKeepsItsLongestEndAndFinishedPreviousTarget() async {
        let words: [LibraryTranscriptItem] = [.init(speaker:"ada",startMs:0,endMs:10000,text:"A long phrase."),
            .init(speaker:"ben",startMs:300,endMs:600,text:"Yes."),.init(speaker:"ada",startMs:700,endMs:1000,text:"Thanks.")]
        let (meeting,audio,fake,listen) = scene(words)
        listen.start("ada",in:meeting); await audio.preparation?.value; fake.sought()
        #expect(fake.boundary?.0 == 10500,"the shorter overlapping turn cannot truncate the chain")
        fake.endedSpan()
        #expect(listen.finished && listen.index == 1 && listen.stepTarget(-1) == 0)
        listen.pageChanged()
    }
    @Test func resumingAfterAClearedSpanReturnsToNormalEOFBehaviour() async {
        let (meeting,audio,fake,_) = scene()
        audio.play(meeting,fromMs:1000,untilMs:1300,onDone:{})
        await audio.preparation?.value; fake.sought(); fake.endedSpan()
        audio.clearSpan(); audio.toggle(meeting); fake.sought()
        #expect(fake.seeks.last?.0 == 1300 && fake.boundary == nil && audio.isPlaying)
        fake.positionMs = 20000; fake.onEnd?()
        #expect(audio.positionMs == 0 && fake.seeks.last?.0 == 0,"ordinary EOF works after consuming a completed span")
        audio.stop()
    }
    @Test func spanIsUncappedClampedAndKeepsItsEndWithoutRewinding() async {
        let (meeting,audio,fake,_) = scene(); var done = 0
        let accepted = audio.play(meeting,fromMs:500,untilMs:12_500,onDone:{ done += 1 })
        #expect(accepted)
        await audio.preparation?.value; fake.sought()
        #expect(fake.boundary?.0 == 12_500 && fake.plays == 1)
        let old = fake.boundary!.1
        fake.endedSpan(); old()
        #expect(done == 1 && !audio.isPlaying && audio.positionMs == 12_500 && fake.seeks.count == 1)
        audio.play(meeting,fromMs:19_500,untilMs:25_000,onDone:{ done += 1 }); fake.sought()
        #expect(fake.boundary?.0 == 20_000)
        fake.positionMs = 20_000; fake.onEnd?()
        #expect(done == 2 && audio.positionMs == 20_000)
        fake.onEnd?()
        #expect(audio.positionMs == 20_000,"an EOS queued after the boundary never rewinds")
        audio.stop()
    }
    @Test func replacedSeeksAndBoundariesCannotFinishOrResumeTheNextSpan() async {
        let (meeting,audio,fake,_) = scene(); var first = 0, second = 0
        audio.play(meeting,fromMs:1000,untilMs:1400,onDone:{ first += 1 })
        await audio.preparation?.value; fake.sought()
        let stale = fake.boundary!.1
        audio.play(meeting,fromMs:5000,untilMs:5400,onDone:{ second += 1 })
        let seek = fake.seeks.last!.1
        audio.play(meeting,fromMs:6000,untilMs:6400,onDone:{ second += 1 })
        seek(true); stale()
        #expect(fake.plays == 1 && first == 0 && second == 0)
        fake.sought(); fake.onEnd?(); stale()
        #expect(fake.boundary?.0 == 6400 && audio.isPlaying && second == 0)
        fake.endedSpan(); stale()
        #expect(first == 0 && second == 1 && audio.positionMs == 6400)
        audio.stop()
    }
    @Test func pauseSeekRateAndClearRespectTheCurrentSpan() async {
        let (meeting,audio,fake,_) = scene(); var done = 0
        audio.play(meeting,fromMs:1000,untilMs:4000,onDone:{ done += 1 })
        await audio.preparation?.value
        audio.toggle(meeting); fake.sought()
        #expect(fake.plays == 0 && fake.boundary == nil)
        audio.rate = 2; audio.toggle(meeting)
        let old = fake.boundary!.1
        audio.seek(toMs:2500); fake.sought(); old()
        #expect(done == 0 && fake.boundary?.0 == 4000 && fake.rate == 2)
        let current = fake.boundary!.1
        audio.clearSpan(); current()
        #expect(done == 0 && audio.isPlaying && audio.positionMs == 2500 && fake.boundary == nil)
        audio.stop()
    }
    @Test func invalidBoundsDoNotStartOrPrepareAudio() {
        let (meeting,audio,fake,_) = scene()
        let nan = audio.play(meeting,fromMs:.nan,untilMs:100,onDone:{})
        let empty = audio.play(meeting,fromMs:100,untilMs:100,onDone:{})
        let infinite = audio.play(meeting,fromMs:100,untilMs:.infinity,onDone:{})
        #expect(!nan && !empty && !infinite)
        #expect(!audio.isPreparing && fake.plays == 0)
    }
}

extension SessionPlaybackTests {
    @Test func pauseAtABoundaryInvalidatesQueuedAdvanceUntilResume() async {
        let (meeting,audio,fake,listen) = scene()
        listen.start("ada",in:meeting); await audio.preparation?.value; fake.sought()
        let queued = fake.boundary!.1
        fake.positionMs = 3800; audio.toggle(meeting); queued(); audio.rate = 2
        #expect(!audio.isPlaying && listen.index == 0 && fake.plays == 1)
        audio.toggle(meeting); fake.sought()
        #expect(listen.index == 1 && audio.isPlaying && fake.seeks.last?.0 == 5500 && fake.rate == 2)
        listen.pageChanged()
    }
    @Test func exactlyTwoSecondsDoesNotChain() async {
        let words: [LibraryTranscriptItem] = [.init(speaker:"ada",startMs:3000,endMs:3300,text:"First."),
            .init(speaker:"ben",startMs:4000,endMs:5000,text:"Yes."),.init(speaker:"ada",startMs:5300,endMs:5600,text:"Next.")]
        let (meeting,audio,fake,listen) = scene(words)
        listen.start("ada",in:meeting); await audio.preparation?.value; fake.sought()
        #expect(fake.boundary?.0 == 3800)
        fake.endedSpan(); fake.sought()
        #expect(fake.seeks.last?.0 == 3800 && fake.boundary?.0 == 6100)
        listen.pageChanged()
    }
    @Test func autoAdvanceUsesBoundaryEventsAndNearbyTurnsAreOneContinuousSpan() async {
        let (meeting,audio,fake,listen) = scene()
        #expect(listen.start("ada",in:meeting))
        await audio.preparation?.value; fake.sought()
        #expect(listen.count == 6 && fake.seeks.last?.0 == 1500 && fake.boundary?.0 == 3800)
        fake.endedSpan(); fake.sought()
        #expect(fake.seeks.last?.0 == 5500 && fake.boundary?.0 == 11800)
        fake.position(9050); #expect(listen.index == 2)
        #expect(listen.stepTarget(1) == 3)
        fake.endedSpan(); fake.sought()
        #expect(fake.seeks.last?.0 == 12500 && fake.boundary?.0 == 15000)
        fake.endedSpan(); fake.sought()
        #expect(fake.seeks.last?.0 == 18200 && fake.boundary?.0 == 20000)
        fake.endedSpan()
        #expect(listen.finished && listen.index == 5 && audio.positionMs == 20000 && !audio.isPlaying)
        #expect(fake.bounds == [3800,11800,15000,20000],"no position event is needed to stop or advance")
        listen.pageChanged()
    }
    @Test func steppingInsideAChainSkipsLeadInAndShortFirstTurnClampsAtZero() async {
        let (meeting,audio,fake,listen) = scene()
        listen.start("ada",in:meeting,turnIndex:2)
        await audio.preparation?.value; fake.sought()
        #expect(fake.seeks.last?.0 == 9000 && fake.boundary?.0 == 11800)
        listen.start("cleo",in:meeting); fake.sought()
        #expect(fake.seeks.last?.0 == 0 && fake.boundary?.0 == 1400)
        fake.endedSpan(); #expect(listen.finished)
        listen.pageChanged()
    }
    @Test func nextDoesNotSkipATurnAfterManualSeekIntoItsLeadIn() async {
        let (meeting,audio,fake,listen) = scene()
        listen.start("ada",in:meeting)
        await audio.preparation?.value; fake.sought()
        #expect(listen.stepTarget(1) == 1 && listen.stepTarget(-1) == nil,"explicit selected lead-in belongs to turn zero")
        fake.positionMs = 16000 // no display-position tick
        #expect(audio.positionMs == 1500 && listen.stepTarget(1) == 5 && listen.stepTarget(-1) == 4,"stepping reads the live media clock")
        audio.seek(toMs:6000); fake.sought()
        #expect(listen.index == 1)
        #expect(listen.stepTarget(1) == 1 && listen.stepTarget(-1) == 0,"manual lead-in seek belongs to the gap before the upcoming turn")
        listen.nextTurn(); fake.sought()
        #expect(listen.index == 1 && fake.seeks.last?.0 == 5500)
        audio.seek(toMs:16000); fake.sought()
        #expect(listen.stepTarget(1) == 5 && listen.stepTarget(-1) == 4)
        listen.previousTurn(); fake.sought()
        #expect(listen.index == 4 && fake.seeks.last?.0 == 12500)
        listen.pageChanged()
    }
    @Test func seeksFollowTheTargetAndStartingMidMeetingUsesTheFirstTurnNotOver() async {
        let (meeting,audio,fake,listen) = scene()
        audio.prepare(meeting); await audio.preparation?.value
        audio.seek(toMs:8000); fake.sought()
        listen.start("ada",in:meeting); fake.sought()
        #expect(listen.index == 2 && fake.seeks.last?.0 == 9000)
        audio.seek(toMs:9100); fake.sought()
        #expect(listen.index == 2 && fake.seeks.last?.0 == 9100 && fake.boundary?.0 == 11800)
        audio.seek(toMs:16000); fake.sought()
        #expect(listen.index == 5 && fake.boundary?.0 == 20000 && fake.seeks.last?.0 == 16000)
        audio.seek(toMs:20000); fake.sought()
        #expect(fake.boundary == nil && listen.finished,"the last tail clamps at the file end")
        listen.start("ada",in:meeting); fake.sought(); #expect(listen.index == 0)
        listen.start("cleo",in:meeting); fake.sought()
        audio.seek(toMs:2000); fake.sought()
        #expect(fake.boundary == nil && !listen.finished && listen.active)
        fake.positionMs = 20000; fake.onState?(.paused); fake.onEnd?()
        #expect(audio.positionMs == 20000 && !audio.isPlaying,"free playback during listening also stays at EOF")
        #expect(listen.finished,"free EOF after a seek past the target must offer Play again")
        audio.toggle(meeting); fake.sought()
        #expect(fake.seeks.last?.0 == 0 && fake.boundary?.0 == 1400)
        listen.pageChanged()
    }
    @Test func staleCompletionCannotFinishPlayAgainOfTheSameTurn() async {
        let (meeting,audio,fake,listen) = scene()
        listen.start("cleo",in:meeting); await audio.preparation?.value; fake.sought()
        let old = fake.boundary!.1
        fake.endedSpan(); #expect(listen.finished)
        listen.playAgain(); fake.sought(); old()
        #expect(!listen.finished && audio.isPlaying && listen.index == 0)
        fake.endedSpan(); #expect(listen.finished)
        listen.pageChanged()
    }
    @Test func mergeRecomputationKeepsPlayAgainAndAReplacedTargetInvalidatesCallbacks() async {
        let words: [LibraryTranscriptItem] = [
            .init(speaker:"cleo",startMs:500,endMs:900,text:"Yes."),.init(speaker:"ben",startMs:1500,endMs:2000,text:"Okay."),
            .init(speaker:"ada",startMs:3000,endMs:3300,text:"Agreed.")]
        let (meeting,audio,fake,listen) = scene(words)
        listen.start("ada",in:meeting); await audio.preparation?.value; fake.sought()
        let old = fake.boundary!.1; fake.endedSpan()
        fake.positionMs = 3799.999 // media-clock quantization after the acknowledged 3800 ms boundary
        let merged = words.map { LibraryTranscriptItem(speaker:$0.speaker == "cleo" ? "ada" : $0.speaker,startMs:$0.startMs,endMs:$0.endMs,text:$0.text) }
        #expect(listen.setTurns(SpeakerTurn.grouping(merged)))
        #expect(listen.finished && listen.count == 2 && listen.index == 1 && audio.positionMs == 3800)
        listen.playAgain(); fake.sought(); old()
        #expect(!listen.finished && listen.index == 0)
        audio.toggle(meeting); audio.seek(toMs:3100); fake.sought()
        listen.setTurns(meeting.speakerTurns); fake.sought()
        #expect(!audio.isPlaying && listen.index == 0)
        let away = words.map { LibraryTranscriptItem(speaker:$0.speaker == "ada" ? "ben" : $0.speaker,startMs:$0.startMs,endMs:$0.endMs,text:$0.text) }
        #expect(!listen.setTurns(SpeakerTurn.grouping(away)) && !listen.active && fake.boundary == nil)
        listen.pageChanged()
    }
    @Test func speakerStepsUsePaneOrderAndStopDoesNotPauseOrSeek() async {
        let (meeting,audio,fake,listen) = scene()
        listen.start("ada",in:meeting); await audio.preparation?.value; fake.sought()
        let order = ["ben","ada","dora","cleo"]
        #expect(listen.speakerStepTarget(1,order:order) == "cleo")
        #expect(listen.speakerStepTarget(-1,order:order) == "ben")
        listen.stepSpeaker(1,order:order); fake.sought()
        #expect(listen.speaker == "cleo" && listen.index == 0 && listen.count == 1)
        let position = audio.positionMs, pauses = fake.pauses, seeks = fake.seeks.count, old = fake.boundary!.1
        listen.stop(); old()
        #expect(!listen.active && audio.isPlaying && audio.positionMs == position && fake.pauses == pauses && fake.seeks.count == seeks)
        audio.stop()
    }
    @Test func pageSwitchGlobalStopAndFailureEndListeningAndFenceLateEvents() async {
        for how in 0..<4 {
            let (meeting,audio,fake,listen) = scene()
            listen.start("ada",in:meeting); await audio.preparation?.value; fake.sought()
            let old = fake.boundary!.1
            if how == 0 { listen.pageChanged() }
            if how == 1 { SessionPlayback.stopAll() }
            if how == 2 { fake.onFailure?(CocoaError(.fileReadUnknown)) }
            if how == 3 { audio.reconcile(nil,offline:true) }
            old()
            #expect(!listen.active && !audio.isPlaying && fake.closes == 1)
        }
        let (meeting,audio,fake,listen) = scene()
        listen.start("ada",in:meeting); let preparing = audio.preparation
        listen.pageChanged(); await preparing?.value
        #expect(!listen.active && !audio.isPlaying && fake.plays == 0)
    }
}
