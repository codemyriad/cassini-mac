import AVFoundation
import Testing
import CassiniLibrary
@testable import CassiniPlayback

/// Offline reads only: no AVPlayer, audio engine, microphone, or output device.
@Suite struct SessionCompositionTests {
    @Test func mixesConcurrentSourcesAtTheirOwnOffsets() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let a = try wave(root, "a", rate: 48000, frames: 14400, value: 1000)
        let b = try wave(root, "b", rate: 48000, frames: 9600, value: 2000)
        let timeline = try await SessionComposition.make(tracks: [.init(url: a, startOffsetMs: 0), .init(url: b, startOffsetMs: 100)])
        let tracks = try await timeline.loadTracks(withMediaType: .audio)
        #expect(tracks.count == 2)
        #expect(abs(CMTimeGetSeconds(timeline.duration) - 0.3) < 0.00001)
        let samples = try read(timeline, start: 0, duration: 0.3)
        #expect(abs(mean(samples, from: 480, to: 4320) - 1000.0 / 32768) < 0.0001)
        #expect(abs(mean(samples, from: 5760, to: 13440) - 3000.0 / 32768) < 0.0001)
        // A non-zero reader range exercises seeking on the composed timeline.
        let seek = try read(timeline, start: 0.2, duration: 0.05)
        #expect(abs(mean(seek, from: 100, to: 2000) - 3000.0 / 32768) < 0.0001)
    }

    @Test func keepsFractionalOffsetsAndResamplesDifferentRates() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let a = try wave(root, "slow", rate: 8000, frames: 800, value: 1000)
        let b = try wave(root, "fast", rate: 48000, frames: 4800, value: 2000)
        let timeline = try await SessionComposition.make(tracks: [.init(url: a, startOffsetMs: 0), .init(url: b, startOffsetMs: 112.5)])
        #expect(abs(CMTimeGetSeconds(timeline.duration) - 0.2125) < 0.00001)
        let samples = try read(timeline, start: 0, duration: 0.2125)
        #expect(abs(mean(samples, from: 480, to: 4320) - 1000.0 / 32768) < 0.0002)
        #expect(abs(mean(samples, from: 4920, to: 5280)) < 0.0001)
        #expect(abs(mean(samples, from: 6000, to: 9600) - 2000.0 / 32768) < 0.0002)
    }

    @Test func refusesUnknownOrInvalidTimingInsteadOfAssumingZero() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let source = try wave(root, "source", rate: 8000, frames: 80, value: 1)
        await #expect(throws: SessionComposition.Failure.noAudio) { try await SessionComposition.make(tracks: []) }
        await #expect(throws: SessionComposition.Failure.unknownOffset) { try await SessionComposition.make(tracks: [.init(url: source, startOffsetMs: nil)]) }
        for invalid in [-1.0, Double.nan, Double.infinity, 86_400_001] {
            await #expect(throws: SessionComposition.Failure.invalidOffset) { try await SessionComposition.make(tracks: [.init(url: source, startOffsetMs: invalid)]) }
        }
    }

    @Test func buildsMainFixtureBudgetReview() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let generator = repo.appendingPathComponent("Tests/CassiniLibraryTests/LibraryVectors/make.py")
        let task = Process(); task.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        task.arguments = [generator.path, root.path]; try task.run(); task.waitUntilExit()
        #expect(task.terminationStatus == 0)
        let scan = try LibraryScanner(root: root.appendingPathComponent("main/root")).scan()
        let meeting = try #require(scan.meetings.first { $0.title == "Budget review" })
        #expect(meeting.canPlaySession)
        let composition = try await SessionComposition.make(tracks: meeting.audioTracks)
        #expect(abs(CMTimeGetSeconds(composition.duration) - 3120) < 0.001)
        #expect(try await composition.loadTracks(withMediaType: .audio).count == meeting.audioFiles.count)
        // The fixture's tone survives through the production scanner and mixer.
        let samples = try read(composition, start: 0, duration: 0.1)
        #expect(samples.contains { abs($0) > 0.01 })
        // A missing source timestamp must stay unknown even though Library's
        // display-duration rule substitutes zero for that track.
        let manifestURL = meeting.folder.appendingPathComponent("session.json")
        var manifest = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any])
        var sources = try #require(manifest["tracks"] as? [[String: Any]])
        sources[0].removeValue(forKey: "startOffsetMs"); manifest["tracks"] = sources
        try JSONSerialization.data(withJSONObject: manifest).write(to: manifestURL)
        let recovered = try #require(LibraryScanner(root: root.appendingPathComponent("main/root")).scan().meetings.first { $0.title == "Budget review" })
        #expect(!recovered.canPlaySession)
        #expect(recovered.audioTracks.first?.startOffsetMs == nil)
        #expect(!recovered.audioFiles.isEmpty)
    }

    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cassini-playback-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); return root
    }
    private func wave(_ root: URL, _ name: String, rate: Int, frames: Int, value: Int16) throws -> URL {
        let url = root.appendingPathComponent(name + ".wav")
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Double(rate), channels: 1, interleaved: true))
        let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatInt16, interleaved: true)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
        buffer.frameLength = AVAudioFrameCount(frames)
        for i in 0..<frames { buffer.int16ChannelData![0][i] = value }
        try file.write(from: buffer); return url
    }
    private func read(_ asset: AVAsset, start: Double, duration: Double) throws -> [Float] {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderAudioMixOutput(audioTracks: asset.tracks(withMediaType: .audio), audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false
        ])
        reader.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 48000), duration: CMTime(seconds: duration, preferredTimescale: 48000))
        reader.add(output); #expect(reader.startReading())
        var samples: [Float] = []
        while let buffer = output.copyNextSampleBuffer(), let block = CMSampleBufferGetDataBuffer(buffer) {
            let count = CMBlockBufferGetDataLength(block)
            var data = Data(count: count)
            let status = data.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: count, destination: $0.baseAddress!) }
            #expect(status == kCMBlockBufferNoErr)
            samples += data.withUnsafeBytes { bytes in stride(from: 0, to: count, by: 4).map { bytes.loadUnaligned(fromByteOffset: $0, as: Float.self) } }
        }
        #expect(reader.status == .completed, "\(String(describing: reader.error))")
        return samples
    }
    private func mean(_ samples: [Float], from: Int, to: Int) -> Double {
        guard samples.count >= to, to > from else { Issue.record("Too few decoded samples: \(samples.count), expected \(to)"); return .nan }
        return samples[from..<to].reduce(0) { $0 + Double($1) } / Double(to - from)
    }
}
