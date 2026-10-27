// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import Testing
@testable import CassiniLibrary
@testable import CassiniPlayback

@MainActor private final class FakeTransport: SessionTransport {
    var onState: ((SessionTransportState) -> Void)?
    var onEnd: (() -> Void)?
    var onFailure: ((Error) -> Void)?
    var onPosition: ((Double) -> Void)?
    var completion: (@MainActor @Sendable (Bool) -> Void)?
    var plays = 0, pauses = 0, closes = 0
    func play() { plays += 1 }
    func pause() { pauses += 1 }
    func rewind(_ completion: @escaping @MainActor @Sendable (Bool) -> Void) { self.completion = completion }
    func close() { closes += 1; onState = nil; onEnd = nil; onFailure = nil }
    func seek(toMs: Double, completion: @escaping @MainActor @Sendable (Bool) -> Void) { self.completion = completion }
    func setRate(_ rate: Float) {}
}
@Suite(.serialized) @MainActor struct SessionPlaybackTests {
    @Test func pausedPreparationSeeksWithoutStartingAndSupersededSeeksCannotResume() async {
        let fake = FakeTransport(), actual = state(fake), meeting = meeting()
        actual.prepare(meeting); actual.seek(toMs: 123)
        await actual.preparation?.value
        fake.completion?(true)
        #expect(fake.plays == 0 && !actual.isPlaying && actual.positionMs == 123)
        actual.toggle(meeting)
        #expect(fake.plays == 1)
        actual.seek(toMs: 300)
        let obsolete = fake.completion
        actual.seek(toMs: 500)
        obsolete?(true)
        #expect(fake.plays == 1 && actual.positionMs == 500)
        fake.completion?(true)
        #expect(fake.plays == 2)
        actual.seek(toMs: 600)
        actual.toggle(meeting)
        fake.completion?(true)
        #expect(!actual.isPlaying && fake.plays == 2)
        actual.stop()
    }
    @Test func finalSeekFailureReturnsToPlayAndReportsOnce() async {
        let fake = FakeTransport(), actual = state(fake)
        var failures = 0
        actual.onFailure = { _ in failures += 1 }
        actual.toggle(meeting()); await actual.preparation?.value
        actual.seek(toMs: 100)
        let callback = fake.completion
        callback?(false); callback?(false)
        #expect(!actual.isPlaying && fake.closes == 1 && failures == 1)
    }
    @Test func pauseRemainsPossibleAfterEligibilityChanges() async {
        let fake = FakeTransport()
        let actual = self.state(fake)
        var meeting = meeting()
        actual.toggle(meeting); await actual.preparation?.value
        meeting.state.lifecycle = .recording
        actual.toggle(meeting)
        #expect(!actual.isPlaying && fake.pauses == 1)
        actual.reconcile(meeting, offline: false)
        #expect(fake.closes == 1)
    }
    @Test func refreshStopsInvalidChangedAndOfflineSources() async {
        for change in 0..<3 {
            let fake = FakeTransport(), state = state(fake)
            var meeting = meeting()
            state.toggle(meeting); await state.preparation?.value
            if change == 0 { meeting.state.lifecycle = .saving }
            if change == 1 { meeting.audioTracks = [.init(url: meeting.audioTracks[0].url, startOffsetMs: 25, frameCount: 8000)] }
            state.reconcile(meeting, offline: change == 2)
            #expect(!state.isPlaying && fake.closes == 1)
        }
    }
    @Test func backendPauseAndMidstreamFailureUpdateUIOnce() async {
        let fake = FakeTransport(), state = state(fake), meeting = meeting()
        var failures = 0; state.onFailure = { _ in failures += 1 }
        state.toggle(meeting); await state.preparation?.value
        fake.onState?(.paused)
        #expect(!state.isPlaying)
        state.toggle(meeting)
        #expect(state.isPlaying && fake.plays == 2)
        let lateFailure = fake.onFailure
        lateFailure?(CocoaError(.fileReadUnknown))
        lateFailure?(CocoaError(.fileReadUnknown))
        #expect(!state.isPlaying && failures == 1 && fake.closes == 1)
    }
    @Test func endWaitsForRewindAndAQueuedPlayCanBeCancelled() async {
        let fake = FakeTransport(), state = state(fake), meeting = meeting()
        state.toggle(meeting); await state.preparation?.value
        fake.onEnd?()
        state.toggle(meeting)
        #expect(state.isPlaying && fake.plays == 1)
        state.toggle(meeting)
        fake.completion?(true)
        #expect(!state.isPlaying && fake.plays == 1)
        state.toggle(meeting)
        #expect(fake.plays == 2)
        state.stop()
    }
    @Test func replayStartsOnlyAfterRewindAndStopInvalidatesCompletion() async {
        let fake = FakeTransport(), state = state(fake), meeting = meeting()
        state.toggle(meeting); await state.preparation?.value
        fake.onEnd?(); state.toggle(meeting)
        #expect(fake.plays == 1)
        fake.completion?(true)
        #expect(fake.plays == 2 && state.isPlaying)
        fake.onEnd?(); state.toggle(meeting)
        let lateRewind = fake.completion
        SessionPlayback.stopAll(); lateRewind?(true)
        #expect(fake.plays == 2 && !state.isPlaying && fake.closes == 1)
    }
    @Test func abandonedPreparationIsCancelledWithItsOwner() async {
        let fake = FakeTransport()
        var state: SessionPlayback? = SessionPlayback(build: { _ in
            try await Task.sleep(for: .seconds(60))
            return SessionTimeline(asset: AVMutableComposition(), storage: PlaybackStorage())
        }, makeTransport: { _ in fake })
        weak var weakState = state
        state!.toggle(meeting())
        let task = state!.preparation!
        state = nil
        #expect(weakState == nil && task.isCancelled)
        await task.value
        #expect(fake.plays == 0)
    }
    private func state(_ fake: FakeTransport) -> SessionPlayback {
        SessionPlayback(build: { _ in SessionTimeline(asset: AVMutableComposition(), storage: PlaybackStorage()) }, makeTransport: { _ in fake })
    }
    private func meeting() -> LibraryMeeting {
        var meeting = LibraryMeeting(id: UUID(), folder: URL(fileURLWithPath: "/tmp/Recording-test"), state: .init(),
            title: "Test", start: nil, durationMs: 1000, speakers: [], quote: nil, notes: [], audioFiles: [], issues: [])
        meeting.audioTracks = [.init(url: URL(fileURLWithPath: "/tmp/track-test.wav"), startOffsetMs: 0, frameCount: 8000)]
        return meeting
    }
}
