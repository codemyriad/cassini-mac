// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import XCTest
@_spi(Testing) import CassiniRecording

final class CheckpointBarrierTests: XCTestCase {
    func testEveryWAVPrecedesSharedDeviceBarrierAndMetadataPublication() throws {
        try exercise()
    }

    func testFileAndDeviceFailuresKeepPriorMetadataAndInvalidateResume() throws {
        try exercise(failing: .audioFileSynchronized)
        try exercise(failing: .audioDeviceSynchronized)
    }

    private func exercise(failing: RecordingCheckpointPhase? = nil) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try RecordingSession(parent: root, title: "Shared device checkpoint", source: "macos")
        for id in ["me", "remote-one", "remote-two", "remote-three"] {
            try session.addTrack(id: id, label: id, kind: "system", sampleRate: 8000, channels: 1)
            try session.appendNative(id: id, pcm: Data(repeating: 1, count: 1600), offsetMs: 0)
        }
        try session.transition(events: [.init(atMs: 0, type: "othersSource", source: "system", reason: "lost")])
        XCTAssertNotNil(session.committedOthersSource)
        let metadata = session.directory.appendingPathComponent("session.json")
        let before = try Data(contentsOf: metadata)
        var phases: [RecordingCheckpointPhase] = []
        session.checkpointObserver = { phase in
            phases.append(phase)
            if phase != .metadataPublished {
                XCTAssertEqual(try Data(contentsOf: metadata), before)
            }
            // Fail after the second file flush, proving a partially flushed batch
            // cannot publish a manifest or authorize a source resume.
            if phase == failing && (phase != .audioFileSynchronized || phases.count == 2) {
                throw CocoaError(.fileWriteOutOfSpace)
            }
        }
        session.requirePeriodicCheckpoint()
        let append = { try session.appendNative(id: "me", pcm: Data(repeating: 2, count: 1600), offsetMs: 100) }
        if failing != nil {
            XCTAssertThrowsError(try append())
            XCTAssertEqual(try Data(contentsOf: metadata), before)
            XCTAssertNil(session.committedOthersSource)
            XCTAssertFalse(phases.contains(.audioSynchronized))
            XCTAssertFalse(phases.contains(.metadataPublished))
            session.checkpointObserver = nil
            try session.transition(events: [.init(atMs: 100, type: "othersSource", source: "system", reason: "lost")])
        } else {
            try append()
            XCTAssertEqual(phases, [.audioFileSynchronized, .audioFileSynchronized,
                                    .audioFileSynchronized, .audioFileSynchronized,
                                    .audioDeviceSynchronized, .audioSynchronized,
                                    .metadataSynchronized, .metadataPublished])
            session.checkpointObserver = nil
        }
        XCTAssertNotNil(session.committedOthersSource)
        let loaded = try RecordingLoader.load(directory: session.directory)
        XCTAssertEqual(loaded.tracks.first(where: { $0.id == "me" })?.frames, 1600)
        XCTAssertEqual(loaded.tracks.filter { $0.id != "me" }.map(\.frames), [800, 800, 800])
        try session.finish()
    }
}
