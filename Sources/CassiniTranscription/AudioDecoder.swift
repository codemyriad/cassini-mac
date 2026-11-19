// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import AVFoundation
import CryptoKit
import Darwin

/// Offline file decoding only. WAV uses physical PCM frames, including a stale
/// checkpoint header. Opus uses AVAudioFile without opening an audio device.
public enum MeetingAudioDecoder {
    public struct CanonicalWAVHeader: Equatable, Sendable {
        public let channels: Int
        public let sampleRate: Int
        public var stride: Int { channels * 2 }
    }

    public static func parseCanonicalWAVHeader(_ data: Data) -> CanonicalWAVHeader? {
        guard data.count == 44 else { return nil }
        func u16(_ at: Int) -> Int { data.withUnsafeBytes { Int(UInt16(littleEndian: $0.loadUnaligned(fromByteOffset: at, as: UInt16.self))) } }
        func u32(_ at: Int) -> Int { data.withUnsafeBytes { Int(UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: at, as: UInt32.self))) } }
        guard data[0..<4] == Data("RIFF".utf8),
              data[8..<16] == Data("WAVEfmt ".utf8),
              data[36..<40] == Data("data".utf8),
              u32(16) == 16, u16(20) == 1, u16(34) == 16,
              [1, 2].contains(u16(22)),
              [16000, 48000].contains(u32(24)),
              u16(32) == u16(22) * 2 else { return nil }
        return CanonicalWAVHeader(channels: u16(22), sampleRate: u32(24))
    }

    public static func pcm16ToMonoFloat(_ block: Data, channels: Int) -> [Float] {
        let stride = channels * 2
        guard stride > 0, block.count >= stride else { return [] }
        var mono = [Float]()
        mono.reserveCapacity(block.count / stride)
        block.withUnsafeBytes { bytes in
            for offset in Swift.stride(from: 0, to: block.count - stride + 1, by: stride) {
                let first = Float(Int16(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: Int16.self))) / 32768
                let value = channels == 1 ? first : (first + Float(Int16(littleEndian: bytes.loadUnaligned(fromByteOffset: offset + 2, as: Int16.self))) / 32768) / 2
                mono.append(value)
            }
        }
        return mono
    }

    public static func decode(_ url: URL, consume: ([Float], Int) throws -> Void) throws {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw TranscriptionFailure.audioFormat }
        var info = stat(); guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { close(fd); throw TranscriptionFailure.audioFormat }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? file.close() }
        if url.pathExtension.lowercased() == "wav" {
            let data = try file.read(upToCount: 44) ?? Data()
            guard let header = parseCanonicalWAVHeader(data) else { throw TranscriptionFailure.audioFormat }
            while let block = try file.read(upToCount: 8192 * header.stride), block.count >= header.stride {
                try consume(pcm16ToMonoFloat(block, channels: header.channels), header.sampleRate)
            }
        } else {
            guard url.pathExtension.lowercased() == "opus" else { throw TranscriptionFailure.audioFormat }
            let audio = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
            let format = audio.processingFormat, rate = Int(format.sampleRate), channels = Int(format.channelCount)
            guard [16000, 48000].contains(rate), [1, 2].contains(channels), let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8192) else { throw TranscriptionFailure.audioFormat }
            while audio.framePosition < audio.length {
                try audio.read(into: buffer)
                guard let data = buffer.floatChannelData, buffer.frameLength > 0 else { break }
                let mono = (0..<Int(buffer.frameLength)).map { channels == 1 ? data[0][$0] : (data[0][$0] + data[1][$0]) / 2 }
                guard mono.allSatisfy({ $0.isFinite }) else { throw TranscriptionFailure.audioFormat }
                try consume(mono, rate)
            }
        }
    }

    /// Decodes a canonical WAV file starting at native frame `fromFrame` (after the 44-byte header).
    static func decodeWAVTail(_ url: URL, expectedHeader: CanonicalWAVHeader, fromFrame: Int, consume: ([Float], Int) throws -> Void) throws {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw TranscriptionFailure.audioFormat }
        var info = stat(); guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { close(fd); throw TranscriptionFailure.audioFormat }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? file.close() }
        let headerData = try file.read(upToCount: 44) ?? Data()
        guard parseCanonicalWAVHeader(headerData) == expectedHeader else { throw TranscriptionFailure.audioFormat }
        let byteOffset = UInt64(44) + UInt64(fromFrame) * UInt64(expectedHeader.stride)
        try file.seek(toOffset: byteOffset)
        while let block = try file.read(upToCount: 8192 * expectedHeader.stride), block.count >= expectedHeader.stride {
            try consume(pcm16ToMonoFloat(block, channels: expectedHeader.channels), expectedHeader.sampleRate)
        }
    }
}

/// Carried incremental segmentation state from `SessionFollower` for warm post-Stop handoff.
/// Reused in `SegmentedAudio` ONLY when the finalized WAV's raw PCM bytes `[0 ..< consumedFrames)`
/// match `wavPrefixSha256` bit-for-bit.
public final class PrecomputedTrackPrefix {
    public let url: URL
    public let header: MeetingAudioDecoder.CanonicalWAVHeader
    public let consumedFrames: Int
    public let wavPrefixSha256: String
    public let sampleCount: Int
    public let segments: [SpeechSegment]
    fileprivate var resampler: MeetingResampler
    fileprivate let detector: any SpeechProbabilityProvider
    fileprivate var gate: SpeechGate
    fileprivate let scratch: SpeechScratch
    fileprivate let stream: FileHandle
    fileprivate var consumed = false

    init(
        url: URL,
        header: MeetingAudioDecoder.CanonicalWAVHeader,
        consumedFrames: Int,
        wavPrefixSha256: String,
        sampleCount: Int,
        segments: [SpeechSegment],
        resampler: MeetingResampler,
        detector: any SpeechProbabilityProvider,
        gate: SpeechGate,
        scratch: SpeechScratch,
        stream: FileHandle
    ) {
        self.url = url
        self.header = header
        self.consumedFrames = consumedFrames
        self.wavPrefixSha256 = wavPrefixSha256
        self.sampleCount = sampleCount
        self.segments = segments
        self.resampler = resampler
        self.detector = detector
        self.gate = gate
        self.scratch = scratch
        self.stream = stream
    }

    deinit {
        if !consumed { try? stream.close() }
    }

    /// Verifies that `url` is a regular canonical WAV file with at least `consumedFrames` physical frames
    /// and that its raw PCM bytes `[44 ..< 44 + consumedFrames * stride)` hash to `wavPrefixSha256`.
    public func verifyMatchesDisk(url diskURL: URL) -> Bool {
        guard !consumed, consumedFrames > 0 else { return false }
        let fd = open(diskURL.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return false }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size >= 44 else {
            close(fd); return false
        }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? file.close() }
        guard let headerData = try? file.read(upToCount: 44),
              MeetingAudioDecoder.parseCanonicalWAVHeader(headerData) == header else { return false }
        let expectedBytes = UInt64(consumedFrames) * UInt64(header.stride)
        guard UInt64(info.st_size) >= 44 + expectedBytes else { return false }
        var hasher = SHA256()
        var remaining = expectedBytes
        while remaining > 0 {
            let toRead = Int(min(remaining, 65536))
            guard let chunk = try? file.read(upToCount: toRead), !chunk.isEmpty else { return false }
            hasher.update(data: chunk)
            remaining -= UInt64(chunk.count)
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return digest == wavPrefixSha256
    }
}

/// Two passes keep memory bounded and make remaining *speech*, rather than
/// recording length, available for D11 ETA. The private scratch is always removed.
public final class SegmentedAudio {
    public private(set) var segments: [SpeechSegment] = []
    public private(set) var sampleCount = 0
    public private(set) var reusedVerifiedPrefix = false
    private let directory: URL
    private let scratch: SpeechScratch
    private let stream: FileHandle
    /// D52 M15: the recognition pass re-decodes a track without VAD, reusing the
    /// segments planned earlier, so only one track's scratch exists at a time.
    public convenience init(url: URL) throws { try self.init(url: url, detector: nil, precomputedPrefix: nil) }
    public convenience init(url: URL, detector: any SpeechProbabilityProvider) throws { try self.init(url: url, detector: Optional(detector), precomputedPrefix: nil) }
    public convenience init(url: URL, detector: any SpeechProbabilityProvider, precomputedPrefix: PrecomputedTrackPrefix?) throws {
        try self.init(url: url, detector: Optional(detector), precomputedPrefix: precomputedPrefix)
    }
    private init(url: URL, detector: (any SpeechProbabilityProvider)?, precomputedPrefix: PrecomputedTrackPrefix?) throws {
        if let prefix = precomputedPrefix, detector != nil, url.pathExtension.lowercased() == "wav", prefix.verifyMatchesDisk(url: url) {
            prefix.consumed = true
            scratch = prefix.scratch
            directory = scratch.directory
            stream = prefix.stream
            sampleCount = prefix.sampleCount
            segments = prefix.segments
            reusedVerifiedPrefix = true
            do {
                try stream.seekToEnd()
                var resampler = prefix.resampler
                var gate = prefix.gate
                let carriedDetector = prefix.detector
                func write(_ pcm: [Float]) throws {
                    sampleCount += pcm.count
                    try pcm.withUnsafeBytes { try stream.write(contentsOf: $0) }
                    segments += try gate.feed(pcm, probability: carriedDetector.probability)
                }
                try MeetingAudioDecoder.decodeWAVTail(url, expectedHeader: prefix.header, fromFrame: prefix.consumedFrames) { pcm, _ in
                    try write(resampler.feed(pcm))
                }
                try write(resampler.feed([], final: true))
                segments += gate.flush()
                carriedDetector.reset()
            } catch {
                try? stream.close()
                throw error
            }
            return
        }
        scratch = try SpeechScratch(); directory = scratch.directory
        let audio = directory.appendingPathComponent("mono.f32")
        guard FileManager.default.createFile(atPath: audio.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw TranscriptionFailure.audioFormat }
        stream = try FileHandle(forUpdating: audio)
        do {
            detector?.reset()
            var resampler: MeetingResampler?, gate = SpeechGate()
            func write(_ pcm: [Float]) throws {
                sampleCount += pcm.count
                try pcm.withUnsafeBytes { try stream.write(contentsOf: $0) }
                if let detector { segments += try gate.feed(pcm, probability: detector.probability) }
            }
            try MeetingAudioDecoder.decode(url) { pcm, rate in
                if resampler == nil { resampler = try MeetingResampler(rate: rate) }
                try write(resampler!.feed(pcm))
            }
            if resampler != nil { try write(resampler!.feed([], final: true)) }
            if let detector { segments += gate.flush(); detector.reset() }
        } catch { try? stream.close(); throw error }
    }
    deinit { try? stream.close() }
    public static func removeAbandonedScratch(in root: URL = FileManager.default.temporaryDirectory) {
        SpeechScratch.removeAbandoned(in: root)
    }
    public func samples(_ segment: SpeechSegment) throws -> [Float] {
        let count = segment.endSample - segment.startSample
        guard count > 0 && count <= 240512 else { throw TranscriptionFailure.audioFormat }
        try stream.seek(toOffset: UInt64(segment.startSample * 4))
        let data = try stream.read(upToCount: count * 4) ?? Data()
        guard data.count == count * 4 else { throw TranscriptionFailure.audioFormat }
        return data.withUnsafeBytes { bytes in (0..<count).map { bytes.loadUnaligned(fromByteOffset: $0 * 4, as: Float.self) } }
    }
    /// D38 reads the raw mono recognizer input, never Silero's HPF samples.
    func rmsDbfs(from startMs: Int64, to endMs: Int64, offsetMs: Int64) throws -> Double? {
        try PCMWindowLevels.measure(stream: stream, sampleCount: sampleCount, from: startMs, to: endMs, offsetMs: offsetMs)
    }
}
