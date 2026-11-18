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
        policy.publish(source, for: "input")
        observers.set(nil)
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
}
