import Foundation
import Testing
@testable import CassiniRecording

private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
private func message(_ value: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: value) }
private func manifest(_ url: URL) throws -> RecordingManifest {
    let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(RecordingManifest.self, from: Data(contentsOf: url.appendingPathComponent("session.json")))
}

@Suite struct RecordingTests {
    @Test func emptySessionAndUnsupportedVersionAreExplicit() throws {
        let parent = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: parent) }
        let host = BrowserRecordingHost(parent: parent)
        #expect(throws: (any Error).self) { _ = try host.receive(message(["type": "start", "version": 2])) }
        _ = try host.receive(message(["type": "start", "version": 1]))
        let response = try host.receive(message(["type": "stop"]))
        #expect(response["problem"] != nil)
        #expect(host.session?.manifest.state == "interrupted")
    }

    @Test func keepsTracksSeparateAndPreservesOffsetsAndGaps() throws {
        let parent = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: parent) }
        let session = try RecordingSession(parent: parent, title: "Test", source: "test")
        try session.addTrack(id: "../../untrusted", label: "Remote", kind: "remote", sampleRate: 48000, channels: 1)
        try session.addTrack(id: "local", label: "Mic", kind: "microphone", sampleRate: 48000, channels: 2)
        try session.append(id: "../../untrusted", pcm: Data(repeating: 1, count: 9600), offsetMs: 250)
        try session.append(id: "../../untrusted", pcm: Data(repeating: 2, count: 9600), offsetMs: 450)
        try session.append(id: "local", pcm: Data(repeating: 3, count: 19200), offsetMs: 100)
        try session.finish()
        let result = try manifest(session.directory)
        #expect(result.state == "completed")
        #expect(result.tracks[0].startOffsetMs == 250)
        #expect(result.tracks[0].frames == 14400)
        #expect(result.tracks[1].frames == 4800)
        #expect(result.tracks.allSatisfy { !$0.file.contains("/") })
        let data = try Data(contentsOf: session.directory.appendingPathComponent(result.tracks[0].file))
        #expect(String(data: data.prefix(4), encoding: .ascii) == "RIFF")
        #expect(data.count == 44 + 28800)
        #expect(data[9644..<19244].allSatisfy { $0 == 0 })
        #expect(data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 40, as: UInt32.self).littleEndian } == 28800)
        #expect(throws: (any Error).self) { try session.append(id: "local", pcm: Data([0, 0, 0, 0]), offsetMs: 200) }
    }

    @Test func validatesSourcesAndChunks() throws {
        let parent = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: parent) }
        let session = try RecordingSession(parent: parent, title: "Test", source: "test")
        #expect(throws: (any Error).self) { try session.addTrack(id: "x", label: "x", kind: "remote", sampleRate: 0, channels: 1) }
        try session.addTrack(id: "x", label: "x", kind: "remote", sampleRate: 48000, channels: 1)
        #expect(throws: (any Error).self) { try session.addTrack(id: "x", label: "x", kind: "remote", sampleRate: 48000, channels: 1) }
        #expect(throws: (any Error).self) { try session.append(id: "x", pcm: Data([1]), offsetMs: 0) }
        #expect(throws: (any Error).self) { try session.append(id: "x", pcm: Data([0, 0]), offsetMs: .nan) }
        try session.append(id: "x", pcm: Data(repeating: 0, count: 9600), offsetMs: 0)
        #expect(throws: (any Error).self) { try session.append(id: "x", pcm: Data([0, 0]), offsetMs: 0) }
        #expect(throws: (any Error).self) { try session.append(id: "x", pcm: Data([0, 0]), offsetMs: 61000) }
        try session.finish(problem: "Device disconnected")
        #expect(try manifest(session.directory).problem == "Device disconnected")
    }

    @Test func browserDisconnectFinalizesPlayablePartialAudio() throws {
        let parent = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: parent) }
        let host = BrowserRecordingHost(parent: parent)
        _ = try host.receive(message(["type": "start"]))
        _ = try host.receive(message(["type": "track", "id": "remote", "kind": "remote", "sampleRate": 48000, "channels": 1]))
        _ = try host.receive(message(["type": "audio", "id": "remote", "sequence": 0, "offsetMs": 0, "pcm": "AQACAA=="]))
        #expect(throws: (any Error).self) {
            _ = try host.receive(message(["type": "audio", "id": "remote", "sequence": 2, "offsetMs": 0, "pcm": "AQACAA=="]))
        }
        let directory = try #require(host.session?.directory)
        // Header is readable before a graceful stop, too.
        let audio = try Data(contentsOf: directory.appendingPathComponent(host.session!.manifest.tracks[0].file))
        #expect(audio.count == 48)
        try host.disconnect()
        let result = try manifest(directory)
        #expect(result.state == "interrupted")
        #expect(result.tracks[0].frames == 2)
        #expect(throws: (any Error).self) { _ = try host.receive(message(["type": "start"])) }
    }

    @Test func browserRejectsAudioBeforeStartAndFinalizesStop() throws {
        let parent = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: parent) }
        let host = BrowserRecordingHost(parent: parent)
        #expect(throws: (any Error).self) { _ = try host.receive(message(["type": "audio"])) }
        _ = try host.receive(message(["type": "start", "title": "Meeting"]))
        _ = try host.receive(message(["type": "track", "id": "x", "kind": "tab", "sampleRate": 48000, "channels": 1]))
        _ = try host.receive(message(["type": "audio", "id": "x", "sequence": 0, "offsetMs": 0, "pcm": "AAAAAA=="]))
        let result = try host.receive(message(["type": "stop"]))
        #expect(result["type"] == "stopped")
        try host.disconnect()
        #expect(host.session?.manifest.state == "completed")
    }

    @Test func framingHandlesRoundTripTruncationAndOversize() throws {
        let parent = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: parent) }
        let url = parent.appendingPathComponent("pipe")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let output = try FileHandle(forWritingTo: url)
        try NativeMessageFraming.write(Data("hello".utf8), to: output)
        try NativeMessageFraming.write(Data("world".utf8), to: output)
        try output.close()
        let input = try FileHandle(forReadingFrom: url); defer { try? input.close() }
        #expect(try NativeMessageFraming.read(from: input) == Data("hello".utf8))
        #expect(try NativeMessageFraming.read(from: input) == Data("world".utf8))
        #expect(try NativeMessageFraming.read(from: input) == nil)
        for invalid in [Data([8, 0, 0, 0, 1, 2]), Data([255, 255, 255, 127]), Data([1, 2])] {
            try invalid.write(to: url)
            let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
            #expect(throws: (any Error).self) { _ = try NativeMessageFraming.read(from: handle) }
        }
    }
}
