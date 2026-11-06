// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import XCTest
import CassiniLibrary
@testable import CassiniPlayback

/// Real, muted AVPlayer over a generated silent WAV. No capture devices or user
/// files; completion/seek notifications are the waits, with timeouts only as bounds.
@MainActor final class AVSpanBoundaryTests: XCTestCase {
    private func fixture() async throws -> (URL,SessionTimeline) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("D70Boundary-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let url = root.appendingPathComponent("silence.wav")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate:44100,channels:1))
        do {
            let writer = try AVAudioFile(forWriting:url,settings:format.settings)
            let pcm = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat:format,frameCapacity:88200)); pcm.frameLength = 88200
            pcm.floatChannelData![0].initialize(repeating:0,count:88200)
            try writer.write(from:pcm)
        }
        let timeline = try await SessionComposition.make(tracks:[.init(url:url,startOffsetMs:0,frameCount:88200,sampleRate:44100)])
        return (root,timeline)
    }
    func testBoundaryStopsA300msSpanWithoutPositionPolling() async throws {
        let (root,timeline) = try await fixture()
        defer { try? FileManager.default.removeItem(at:root) }
        let player = AVPlayer(); player.volume = 0
        let transport = AVSessionTransport(timeline,player:player)
        defer { transport.close() }
        let ended = expectation(description:"AVPlayer boundary at 423 ms (between 44.1 kHz sample boundaries)")
        var ends = 0, fileEnds = 0
        transport.onEnd = { fileEnds += 1 }
        transport.onPosition = nil
        transport.seek(toMs:123) { ready in
            XCTAssertTrue(ready)
            transport.setBoundary(atMs:423) { ends += 1; ended.fulfill() }
            transport.play()
        }
        await fulfillment(of:[ended],timeout:10)
        XCTAssertEqual(ends,1); XCTAssertEqual(fileEnds,0)
        XCTAssertEqual(player.rate,0)
        XCTAssertEqual(transport.positionMs,423,accuracy:1)
    }
    func testRateChangeAtTheEndAndQueuedEOSCannotEndTheNextSpan() async throws {
        let (root,timeline) = try await fixture()
        defer { try? FileManager.default.removeItem(at:root) }
        let player = AVPlayer(); player.volume = 0
        let transport = AVSessionTransport(timeline,player:player)
        defer { transport.close() }
        let ended = expectation(description:"replacement boundary at 1100 ms")
        var first = 0, second = 0, fileEnds = 0
        transport.onEnd = { fileEnds += 1 }
        transport.setBoundary(atMs:400) {
            first += 1
            transport.seek(toMs:800) { ready in
                XCTAssertTrue(ready)
                transport.setBoundary(atMs:1100) { second += 1; ended.fulfill() }
                NotificationCenter.default.post(name:.AVPlayerItemDidPlayToEndTime,object:player.currentItem)
                transport.play()
            }
        }
        // Seeking to the exact end exposes the rate-change/EOS race deterministically:
        // setRate runs in the seek completion before a queued end can be dispatched.
        transport.seek(toMs:400) { ready in XCTAssertTrue(ready); transport.setRate(2) }
        await fulfillment(of:[ended],timeout:10)
        XCTAssertEqual(first,1); XCTAssertEqual(second,1); XCTAssertEqual(fileEnds,0)
        XCTAssertEqual(transport.positionMs,1100,accuracy:1)
        transport.setRate(1.5); XCTAssertEqual(player.rate,0)
    }
}
