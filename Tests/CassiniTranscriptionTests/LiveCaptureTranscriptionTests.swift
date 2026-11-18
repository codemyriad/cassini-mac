import Foundation
import Synchronization
import XCTest
import CassiniRecording
import CassiniWhistle
@testable import CassiniTranscription

final class LiveCaptureTranscriptionTests: XCTestCase {
    func testDiscontinuitySettlesTwoSeparateAudioSpans() async throws {
        let (stream, continuation) = AsyncStream<LivePCMEvent>.makeStream()
        let pcm = Data(repeating: 1, count: 16_000 * 2)
        let source = RecordedPCMSource(id: "remote", kind: "remote", sampleRate: 16_000, channels: 1, startOffsetMs: 100)
        continuation.yield(.audio(source: source, pcm16LE: pcm, offsetMs: 100))
        continuation.yield(.audio(source: source, pcm16LE: pcm, offsetMs: 2100))
        continuation.finish()

        let updates = Mutex<[LiveCaptureTranscription.Revision]>([])
        try await LiveCaptureTranscription.follow(stream, decode: { samples in
            XCTAssertEqual(samples.count, 16_000)
            return WhistleTranscript(text: "hello", language: "en",
                                     words: [.init(word: "hello", start: 0.1, end: 0.3, probability: 1)])
        }, update: { revision in updates.withLock { $0.append(revision) } })
        let revisions = updates.withLock { $0 }
        XCTAssertEqual(revisions.map(\.source), ["remote", "remote"])
        XCTAssertEqual(revisions.map(\.settledMs), [1100, 3100])
        XCTAssertEqual(revisions.flatMap { $0.words.map(\.start) }, [0.2, 2.2])
    }
}
