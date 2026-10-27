// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import AVFoundation
import Darwin

/// Offline file decoding only. WAV uses physical PCM frames, including a stale
/// checkpoint header. Opus uses AVAudioFile without opening an audio device.
public enum MeetingAudioDecoder {
    public static func decode(_ url: URL, consume: ([Float], Int) throws -> Void) throws {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw TranscriptionFailure.audioFormat }
        var info = stat(); guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { close(fd); throw TranscriptionFailure.audioFormat }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? file.close() }
        if url.pathExtension.lowercased() == "wav" {
            let data = try file.read(upToCount: 44) ?? Data()
            func u16(_ at: Int) -> Int { data.withUnsafeBytes { Int(UInt16(littleEndian: $0.loadUnaligned(fromByteOffset: at, as: UInt16.self))) } }
            func u32(_ at: Int) -> Int { data.withUnsafeBytes { Int(UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: at, as: UInt32.self))) } }
            guard data.count == 44, data[0..<4] == Data("RIFF".utf8), data[8..<16] == Data("WAVEfmt ".utf8), data[36..<40] == Data("data".utf8), u32(16) == 16, u16(20) == 1, u16(34) == 16, [1,2].contains(u16(22)), [16000,48000].contains(u32(24)), u16(32) == u16(22) * 2 else { throw TranscriptionFailure.audioFormat }
            let channels = u16(22), rate = u32(24), stride = channels * 2
            while let block = try file.read(upToCount: 8192 * stride), block.count >= stride {
                var mono = [Float](); mono.reserveCapacity(block.count / stride)
                block.withUnsafeBytes { bytes in
                    for offset in Swift.stride(from: 0, to: block.count - stride + 1, by: stride) {
                        let first = Float(Int16(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: Int16.self))) / 32768
                        let value = channels == 1 ? first : (first + Float(Int16(littleEndian: bytes.loadUnaligned(fromByteOffset: offset + 2, as: Int16.self))) / 32768) / 2
                        mono.append(value)
                    }
                }
                try consume(mono, rate)
            }
        } else {
            guard url.pathExtension.lowercased() == "opus" else { throw TranscriptionFailure.audioFormat }
            let audio = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
            let format = audio.processingFormat, rate = Int(format.sampleRate), channels = Int(format.channelCount)
            guard [16000,48000].contains(rate), [1,2].contains(channels), let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8192) else { throw TranscriptionFailure.audioFormat }
            while audio.framePosition < audio.length {
                try audio.read(into: buffer)
                guard let data = buffer.floatChannelData, buffer.frameLength > 0 else { break }
                let mono = (0..<Int(buffer.frameLength)).map { channels == 1 ? data[0][$0] : (data[0][$0] + data[1][$0]) / 2 }
                guard mono.allSatisfy({ $0.isFinite }) else { throw TranscriptionFailure.audioFormat }
                try consume(mono, rate)
            }
        }
    }
}

/// Two passes keep memory bounded and make remaining *speech*, rather than
/// recording length, available for D11 ETA. The private scratch is always removed.
public final class SegmentedAudio {
    public private(set) var segments: [SpeechSegment] = []
    public private(set) var sampleCount = 0
    private let directory: URL
    private let stream: FileHandle
    public init(url: URL, detector: SpeechDetector) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("CassiniSpeech-" + String(getpid()) + "-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let scratch = directory.appendingPathComponent("mono.f32")
        guard FileManager.default.createFile(atPath: scratch.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { try? FileManager.default.removeItem(at: directory); throw TranscriptionFailure.audioFormat }
        stream = try FileHandle(forUpdating: scratch)
        do {
            detector.reset()
            var resampler: MeetingResampler?, gate = SpeechGate()
            func write(_ pcm: [Float]) throws {
                sampleCount += pcm.count
                try pcm.withUnsafeBytes { try stream.write(contentsOf: $0) }
                segments += try gate.feed(pcm, probability: detector.probability)
            }
            try MeetingAudioDecoder.decode(url) { pcm, rate in
                if resampler == nil { resampler = try MeetingResampler(rate: rate) }
                try write(resampler!.feed(pcm))
            }
            if resampler != nil { try write(resampler!.feed([], final: true)) }
            segments += gate.flush(); detector.reset()
        } catch { try? stream.close(); try? FileManager.default.removeItem(at: directory); throw error }
    }
    deinit { try? stream.close(); try? FileManager.default.removeItem(at: directory) }
    public static func removeAbandonedScratch() {
        let root = FileManager.default.temporaryDirectory
        for directory in (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
            let name = directory.lastPathComponent
            guard name.hasPrefix("CassiniSpeech-") else { continue }
            let parts = name.dropFirst("CassiniSpeech-".count).split(separator: "-", maxSplits: 1)
            guard parts.count == 2, let pid = Int32(parts[0]), pid > 0, UUID(uuidString: String(parts[1])) != nil else { continue }
            var info = stat()
            guard lstat(directory.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid(), info.st_mode & 0o777 == 0o700,
                  kill(pid, 0) != 0, errno == ESRCH else { continue }
            try? FileManager.default.removeItem(at: directory)
        }
    }
    public func samples(_ segment: SpeechSegment) throws -> [Float] {
        let count = segment.endSample - segment.startSample
        guard count > 0 && count <= 240512 else { throw TranscriptionFailure.audioFormat }
        try stream.seek(toOffset: UInt64(segment.startSample * 4))
        let data = try stream.read(upToCount: count * 4) ?? Data()
        guard data.count == count * 4 else { throw TranscriptionFailure.audioFormat }
        return data.withUnsafeBytes { bytes in (0..<count).map { bytes.loadUnaligned(fromByteOffset: $0 * 4, as: Float.self) } }
    }
}
