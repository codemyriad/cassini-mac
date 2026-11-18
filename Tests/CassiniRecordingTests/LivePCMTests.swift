import Foundation
import XCTest
@testable import CassiniRecording

final class LivePCMTests: XCTestCase {
    func testNativeBootstrapReachesLiveConsumerWithoutVisualObserver() async {
        let observers = RecordedPCMObservers()
        let policy = RecordedPCMPolicy(observers: observers)
        let stream = observers.livePCM()
        let pcm = Data([1, 0, 2, 0])
        let source = RecordedPCMSource(id: "mic", kind: "microphone", sampleRate: 48_000,
                                       channels: 1, startOffsetMs: 100)
        policy.offer(inputID: "input", pcm: pcm, offsetMs: 100)
        observers.set(nil)
        policy.publish(source, for: "input")
        observers.sourceEnded(id: source.id)
        observers.finishLive()
        var reader = stream.makeAsyncIterator()
        if case let .audio(actual, bytes, offset) = await reader.next() {
            XCTAssertEqual(actual, source)
            XCTAssertEqual(bytes, pcm)
            XCTAssertEqual(offset, 100)
        } else {
            XCTFail("Expected bootstrapped PCM")
        }
        if case let .ended(id) = await reader.next() {
            XCTAssertEqual(id, source.id)
        } else {
            XCTFail("Expected source end")
        }
        let end = await reader.next()
        XCTAssertNil(end)
    }

    func testSourceEndSurvivesAudioOverflowAndSessionFinishClosesFeed() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try RecordingSession(parent: root, title: "test", source: "chromium")
        let input = session.pcmObservers.livePCM()
        session.pcmObservers.sourceEnded(id: "retired")
        let active = RecordedPCMSource(id: "remote", kind: "remote", sampleRate: 48_000,
                                       channels: 1, startOffsetMs: 0)
        for index in 0..<40 {
            session.pcmObservers.offer(source: active, pcm: Data([1, 0]), offsetMs: Double(index))
        }
        try session.finish()
        var iterator = input.makeAsyncIterator()
        if case let .ended(id)? = await iterator.next() {
            XCTAssertEqual(id, "retired")
        } else {
            XCTFail("Audio overflow evicted the source-end event")
        }
        var offsets: [Double] = []
        while let event = await iterator.next() {
            if case let .audio(_, _, offset) = event { offsets.append(offset) }
        }
        XCTAssertEqual(offsets, (8..<40).map(Double.init))
        var finished = session.pcmObservers.livePCM().makeAsyncIterator()
        let end = await finished.next()
        XCTAssertNil(end)
    }
}
