// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import XCTest
import CassiniKit
@_spi(Testing) import CassiniRecording
@_spi(Testing) @testable import CassiniBrowserControl

private final class CheckpointPCM: RecordedPCMObserver, @unchecked Sendable {
    private let lock = NSLock()
    private var packets: [Data] = []
    func offer(source: RecordedPCMSource, pcm: Data, offsetMs: Double) { lock.withLock { packets.append(pcm) } }
    var snapshot: [Data] { lock.withLock { packets } }
}
private final class CheckpointWriteResult: @unchecked Sendable {
    private let lock = NSLock(); private var failure: String?
    func fail(_ error: Error) { lock.withLock { failure = String(describing:error) } }
    var error: String? { lock.withLock { failure } }
}
final class PCMCheckpointTests: XCTestCase, @unchecked Sendable {
    func testWrittenBrowserPCMIsAvailableBeforeItsPeriodicDurabilityCheckpointCompletes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PCM-checkpoint-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let owner = try OwnedBrowserCapture(parent:root,title:"Private checkpoint boundary",microphone:false)
        try owner.browserTrack(id:"remote",label:"Remote",kind:"remote",sampleRate:8000,channels:1)
        let snapshot = owner.snapshot
        let track = try XCTUnwrap(snapshot.manifest.tracks.first)
        let pcm = Data(repeating:0,count:1600), probe = CheckpointPCM()
        owner.pcmObservers.set(probe)
        let held = expectation(description:"Real append reached audio synchronization"), done = expectation(description:"Browser append completed")
        let release = DispatchSemaphore(value:0), result = CheckpointWriteResult()
        owner.setCheckpointObserver { phase in
            if phase == .audioSynchronized { held.fulfill(); release.wait() }
        }
        owner.requirePeriodicCheckpoint()
        Thread {
            do { try owner.browserAudio(id:"remote",sequence:0,offsetMs:0,pcm:pcm) } catch { result.fail(error) }
            done.fulfill()
        }.start()
        await fulfillment(of:[held],timeout:5)
        // PCM is already present in the real WAV, but session.json still has its
        // previous committed frame count. A picture must not wait for that sync.
        let bytes = try? Data(contentsOf:snapshot.directory.appendingPathComponent(track.file))
        XCTAssertEqual(bytes?.suffix(pcm.count),pcm)
        let metadata = (try? Data(contentsOf:snapshot.directory.appendingPathComponent("session.json"))).flatMap { try? JSONParser.parse($0) }
        XCTAssertEqual(metadata?["tracks"]?.array?.first?["frames"]?.int,0,"Durability publication must remain after the held checkpoint")
        XCTAssertEqual(probe.snapshot,[pcm],"The recorded PCM observer must be independent of a periodic durability stall")
        release.signal()
        await fulfillment(of:[done],timeout:5)
        owner.setCheckpointObserver(nil)
        XCTAssertNil(result.error)
        XCTAssertEqual(probe.snapshot,[pcm],"Checkpoint completion must not duplicate picture input")
        try await owner.finish()
    }
}
