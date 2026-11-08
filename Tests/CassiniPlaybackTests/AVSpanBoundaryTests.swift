// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import Observation
import XCTest
@testable import CassiniLibrary
@testable import CassiniPlayback

/// Real muted AVPlayer, through the production owner/controller. All waits are
/// seek/KVO/observation events; only generated media in private temporary roots.
@MainActor final class AVSpanBoundaryTests: XCTestCase {
    @MainActor private struct Scene {
        let root: URL, meeting: LibraryMeeting, player: AVPlayer
        let transport: AVSessionTransport, audio: SessionPlayback
        func close() { audio.stop(); transport.close(); try? FileManager.default.removeItem(at:root) }
    }
    private func fixture(rate: Int = 44100) async throws -> Scene {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("D70Boundary-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        do {
            let url = root.appendingPathComponent("silence.wav")
            let frames = AVAudioFrameCount(rate*4)
            let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate:Double(rate),channels:1))
            do {
                let writer = try AVAudioFile(forWriting:url,settings:format.settings)
                let pcm = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat:format,frameCapacity:frames)); pcm.frameLength = frames
                pcm.floatChannelData![0].initialize(repeating:0,count:Int(frames))
                try writer.write(from:pcm)
            }
            let tracks: [LibraryAudioTrack] = [.init(url:url,startOffsetMs:0,frameCount:UInt64(frames),sampleRate:rate)]
            let timeline = try await SessionComposition.make(tracks:tracks)
            let player = AVPlayer(); player.isMuted = true; player.volume = 0
            let transport = AVSessionTransport(timeline,player:player)
            let audio = SessionPlayback(build:{ _ in timeline },makeTransport:{ _ in transport })
            var meeting = LibraryMeeting(id:UUID(),folder:root,state:.init(),title:"Synthetic call",start:nil,
                durationMs:4000,speakers:[],quote:nil,notes:[],audioFiles:[url],issues:[])
            meeting.audioTracks = tracks
            return .init(root:root,meeting:meeting,player:player,transport:transport,audio:audio)
        } catch { try? FileManager.default.removeItem(at:root); throw error }
    }
    private func started(_ player: AVPlayer) -> (XCTestExpectation,NSKeyValueObservation) {
        let event = expectation(description:"native player starts"); event.assertForOverFulfill = false
        let observation = player.observe(\.timeControlStatus,options:[.new]) { player,_ in
            if player.timeControlStatus == .playing { event.fulfill() }
        }
        return (event,observation)
    }
    private func sampleBefore(_ ms: Double, rate: Int) -> Double {
        (ceil(ms*Double(rate)/1000)-1)*1000/Double(rate)
    }
    /// A one-shot observation that also handles completion before registration.
    @MainActor private final class Finished {
        let listen: ListenController, event: XCTestExpectation
        private var done = false
        init(_ listen: ListenController, event: XCTestExpectation) { self.listen = listen; self.event = event; watch() }
        private func watch() {
            guard !done else { return }
            let finished = withObservationTracking { listen.finished } onChange: { [weak self] in
                Task { @MainActor [weak self] in self?.watch() }
            }
            if finished { done = true; event.fulfill() }
        }
    }
    @MainActor private final class Advanced {
        let listen: ListenController, event: XCTestExpectation
        private var done = false
        init(_ listen: ListenController, event: XCTestExpectation) { self.listen = listen; self.event = event; watch() }
        private func watch() {
            guard !done else { return }
            let index = withObservationTracking { listen.index } onChange: { [weak self] in
                Task { @MainActor [weak self] in self?.watch() }
            }
            if index >= 1 { done = true; event.fulfill() }
        }
    }
    func testOvershotBoundarySettlesThePhysicalClockBeforeCompletion() async throws {
        let scene = try await fixture(); defer { scene.close() }
        let ended = expectation(description:"overshot native boundary completes after exact seek")
        XCTAssertTrue(scene.audio.play(scene.meeting,fromMs:123,untilMs:423) { ended.fulfill() })
        await scene.audio.preparation?.value
        scene.player.pause()
        let overshot = expectation(description:"real player clock placed beyond the requested boundary")
        scene.transport.seek(toMs:426) { ready in
            XCTAssertTrue(ready)
            XCTAssertGreaterThan(scene.transport.positionMs,424)
            scene.transport.timeControlStatusChanged()
            overshot.fulfill()
        }
        await fulfillment(of:[overshot,ended],timeout:10)
        XCTAssertEqual(scene.transport.positionMs,423,accuracy:1,"Boundary completion must settle the physical clock")
        XCTAssertEqual(scene.audio.positionMs,423)
        XCTAssertFalse(scene.audio.isPlaying)
    }
    func testBoundaryStopsA300msSpanWithoutPositionPolling() async throws {
        let scene = try await fixture(); defer { scene.close() }
        let ended = expectation(description:"owned boundary at fractional-sample 423 ms")
        var ends = 0
        XCTAssertTrue(scene.audio.play(scene.meeting,fromMs:123,untilMs:423) { ends += 1; ended.fulfill() })
        await scene.audio.preparation?.value
        XCTAssertNotNil(scene.transport.onState); XCTAssertNotNil(scene.transport.onEnd)
        scene.transport.onPosition = nil // Completion cannot depend on periodic position ticks.
        await fulfillment(of:[ended],timeout:10)
        XCTAssertEqual(ends,1); XCTAssertFalse(scene.audio.isPlaying)
        XCTAssertEqual(scene.audio.positionMs,423)
        XCTAssertEqual(scene.player.rate,0)
        XCTAssertEqual(scene.transport.positionMs,423,accuracy:1)
    }
    func testPausedFirstAtQuantizedEndAdvancesAndFinishesListening() async throws {
        for rate in [44100,16000,8000] {
            let scene = try await fixture(rate:rate); defer { scene.close() }
            var meeting = scene.meeting
            meeting.transcriptItems = [.init(speaker:"ada",startMs:123,endMs:423,text:"Yes."),
                .init(speaker:"sam",startMs:1100,endMs:1200,text:"Agreed."),
                .init(speaker:"ada",startMs:3000,endMs:3303,text:"Next.")]
            let listen = ListenController(playback:scene.audio); listen.setTurns(meeting.speakerTurns)
            scene.audio.rate = 2
            let (playing,observation) = started(scene.player); defer { observation.invalidate() }
            XCTAssertTrue(listen.start("ada",in:meeting))
            await fulfillment(of:[playing],timeout:10)
            XCTAssertNotNil(scene.transport.onState); XCTAssertNotNil(scene.transport.onEnd)
            // Hold the real clock at the final whole sample before the 923 ms stop.
            // Deliver the production paused-KVO handler before queued boundary/EOS work.
            scene.player.pause()
            let paused = expectation(description:"paused-first KVO at \(rate) Hz")
            let advanced = expectation(description:"listening advances after physical clock settles")
            let advancement = Advanced(listen,event:advanced)
            scene.transport.seek(toMs:sampleBefore(923,rate:rate)) { ready in
                XCTAssertTrue(ready)
                XCTAssertEqual(scene.player.timeControlStatus,.paused)
                XCTAssertLessThan(scene.transport.positionMs,923)
                XCTAssertEqual(scene.transport.positionMs,923,accuracy:1)
                scene.transport.timeControlStatusChanged()
                paused.fulfill()
            }
            await fulfillment(of:[paused,advanced],timeout:10)
            withExtendedLifetime(advancement) {}
            XCTAssertEqual(listen.index,1,"paused-before-boundary must advance at \(rate) Hz")
            guard listen.index == 1 else { continue }
            XCTAssertFalse(listen.finished)
            let ended = expectation(description:"final native listening span at \(rate) Hz")
            let finished = Finished(listen,event:ended)
            await fulfillment(of:[ended],timeout:10)
            withExtendedLifetime(finished) {}
            XCTAssertTrue(listen.finished); XCTAssertEqual(listen.count,2)
            XCTAssertEqual(scene.audio.positionMs,3803)
            XCTAssertFalse(scene.audio.isPlaying); XCTAssertEqual(scene.player.rate,0)
            XCTAssertEqual(scene.transport.positionMs,3803,accuracy:1)
        }
    }
    func testRateChangeAtFractionalEndAndQueuedEOSCannotEndTheNextOwnedSpan() async throws {
        let scene = try await fixture(); defer { scene.close() }
        let ended = expectation(description:"replacement owned span at 1123 ms")
        let (playing,observation) = started(scene.player); defer { observation.invalidate() }
        var first = 0, second = 0
        XCTAssertTrue(scene.audio.play(scene.meeting,fromMs:123,untilMs:423) {
            first += 1
            XCTAssertTrue(scene.audio.play(scene.meeting,fromMs:823,untilMs:1123) { second += 1; ended.fulfill() })
            NotificationCenter.default.post(name:.AVPlayerItemDidPlayToEndTime,object:scene.player.currentItem)
        })
        await fulfillment(of:[playing],timeout:10)
        XCTAssertNotNil(scene.transport.onState); XCTAssertNotNil(scene.transport.onEnd)
        scene.player.pause()
        scene.transport.seek(toMs:sampleBefore(423,rate:44100)) { ready in
            XCTAssertTrue(ready)
            scene.audio.rate = 2 // Runs before the queued paused/boundary events.
        }
        await fulfillment(of:[ended],timeout:10)
        XCTAssertEqual(first,1); XCTAssertEqual(second,1)
        XCTAssertEqual(scene.audio.positionMs,1123); XCTAssertFalse(scene.audio.isPlaying)
        XCTAssertEqual(scene.transport.positionMs,1123,accuracy:1)
        scene.audio.rate = 1.5; XCTAssertEqual(scene.player.rate,0)
    }
    func testPhysicalEOFRecognizesTheLastAudioFrame() async throws {
        let scene = try await fixture(rate:8000); defer { scene.close() }
        let (playing,observation) = started(scene.player); defer { observation.invalidate() }
        scene.audio.play(scene.meeting,fromMs:123)
        await fulfillment(of:[playing],timeout:10)
        let ended = expectation(description:"physical EOF within one 8 kHz sample")
        scene.player.pause()
        scene.transport.seek(toMs:sampleBefore(4000,rate:8000)) { ready in
            XCTAssertTrue(ready)
            NotificationCenter.default.post(name:.AVPlayerItemDidPlayToEndTime,object:scene.player.currentItem)
            XCTAssertEqual(scene.audio.positionMs,0,"ordinary EOF was recognized and requested rewind")
            ended.fulfill()
        }
        await fulfillment(of:[ended],timeout:10)
    }
}
