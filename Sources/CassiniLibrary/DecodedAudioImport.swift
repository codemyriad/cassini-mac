// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import AudioToolbox
import CassiniKit
import Darwin
import Foundation

public enum DecodedAudioImportError: LocalizedError, Equatable, Sendable {
    case unsupportedFormat(String)
    case unreadableAudio
    case emptyAudio
    case encodingFailed

    public var errorDescription: String? {
        LibraryLocalization.shared.text("mac.import.error.decodeFailed")
    }
}

/// Offline audio decoder and Ogg Opus muxer for `MP3`, `M4A`, and `WAV` imports (`L-25` / `D-1028`).
/// Streams PCM in bounded chunks, mixes multichannel audio to mono 48 kHz Float32, and encodes
/// 20 ms (960-sample) Opus packets via software `AVAudioConverter` without opening any audio device.
enum DecodedAudioImport {
    private static let chunkCapacity: AVAudioFrameCount = 8_192
    private static let opusFrameSamples = 960
    private static let targetSampleRate: Double = 48_000
    private static let targetBitrateBps = 64_000

    static func requiresTranscode(typeID: String) -> Bool {
        switch typeID {
        case "mp3", "m4a", "wav":
            return true
        default:
            return false
        }
    }

    static func transcodeToOpus(
        sourceURL: URL,
        typeID: String,
        destinationURL: URL,
        shouldCancel: () -> Bool = { false }
    ) throws {
        guard requiresTranscode(typeID: typeID) else {
            throw DecodedAudioImportError.unsupportedFormat(typeID)
        }
        if shouldCancel() { throw CancellationError() }

        try validateContainerHeader(at: sourceURL, typeID: typeID)

        let inFile: AVAudioFile
        do {
            inFile = try AVAudioFile(forReading: sourceURL, commonFormat: .pcmFormatFloat32, interleaved: false)
        } catch {
            throw DecodedAudioImportError.unreadableAudio
        }

        let fileFormatID = inFile.fileFormat.streamDescription.pointee.mFormatID
        guard isAllowedAudioFormatID(fileFormatID, for: typeID) else {
            throw DecodedAudioImportError.unsupportedFormat(String(fileFormatID))
        }

        let processingFormat = inFile.processingFormat
        let channelCount = Int(processingFormat.channelCount)
        guard channelCount >= 1,
              processingFormat.sampleRate > 0,
              processingFormat.sampleRate.isFinite,
              inFile.length > 0 else {
            throw DecodedAudioImportError.emptyAudio
        }

        guard let monoSourceFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: processingFormat.sampleRate,
            channels: 1,
            interleaved: false
        ),
        let pcm48Format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetSampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw DecodedAudioImportError.encodingFailed
        }

        let resampler: AVAudioConverter?
        if processingFormat.sampleRate == targetSampleRate {
            resampler = nil
        } else {
            guard let conv = AVAudioConverter(from: monoSourceFormat, to: pcm48Format) else {
                throw DecodedAudioImportError.encodingFailed
            }
            conv.sampleRateConverterQuality = AVAudioQuality.max.rawValue
            conv.primeMethod = .none
            resampler = conv
        }

        var opusASBD = AudioStreamBasicDescription(
            mSampleRate: targetSampleRate,
            mFormatID: kAudioFormatOpus,
            mFormatFlags: 0,
            mBytesPerPacket: 0,
            mFramesPerPacket: UInt32(opusFrameSamples),
            mBytesPerFrame: 0,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 0,
            mReserved: 0
        )
        guard let opusFormat = AVAudioFormat(streamDescription: &opusASBD),
              let encoder = AVAudioConverter(from: pcm48Format, to: opusFormat) else {
            throw DecodedAudioImportError.encodingFailed
        }
        encoder.bitRate = targetBitrateBps
        let preSkip = Int(encoder.primeInfo.leadingFrames)
        guard (0...65535).contains(preSkip) else {
            throw DecodedAudioImportError.encodingFailed
        }

        let writer = try OpusPacketWriter(
            url: destinationURL,
            head: try OpusPacketWriter.monoHead(preSkip: preSkip),
            tags: PortableMeetingTags.packet()
        )

        guard let readBuffer = AVAudioPCMBuffer(pcmFormat: processingFormat, frameCapacity: chunkCapacity),
              let monoBuffer = AVAudioPCMBuffer(pcmFormat: monoSourceFormat, frameCapacity: chunkCapacity),
              let frame960Buffer = AVAudioPCMBuffer(pcmFormat: pcm48Format, frameCapacity: AVAudioFrameCount(opusFrameSamples)) else {
            throw DecodedAudioImportError.encodingFailed
        }
        let maxPacketBytes = max(encoder.maximumOutputPacketSize, 4096)
        let packetBuffer = AVAudioCompressedBuffer(format: opusFormat, packetCapacity: 1, maximumPacketSize: maxPacketBytes)

        var pending: [Float] = []
        pending.reserveCapacity(opusFrameSamples * 4)
        var pendingOffset = 0
        var totalSamples48k: Int64 = 0

        func encodeOneFrame(_ slice: ArraySlice<Float>) throws {
            if shouldCancel() { throw CancellationError() }
            frame960Buffer.frameLength = AVAudioFrameCount(opusFrameSamples)
            guard let dst = frame960Buffer.floatChannelData?[0] else {
                throw DecodedAudioImportError.encodingFailed
            }
            var idx = 0
            for sample in slice {
                dst[idx] = sample
                idx += 1
            }
            while idx < opusFrameSamples {
                dst[idx] = 0
                idx += 1
            }

            packetBuffer.byteLength = 0
            packetBuffer.packetCount = 0
            var supplied = false
            var convError: NSError?
            let status = encoder.convert(to: packetBuffer, error: &convError) { _, outStatus in
                if !supplied {
                    supplied = true
                    outStatus.pointee = .haveData
                    return frame960Buffer
                }
                outStatus.pointee = .noDataNow
                return nil
            }
            if convError != nil || status != .haveData || packetBuffer.packetCount != 1 {
                throw DecodedAudioImportError.encodingFailed
            }
            guard let descs = packetBuffer.packetDescriptions else {
                throw DecodedAudioImportError.encodingFailed
            }
            let desc = descs[0]
            let pktCount = Int(desc.mDataByteSize)
            let pktStart = Int(desc.mStartOffset)
            guard pktCount > 0, pktStart >= 0, pktStart + pktCount <= Int(packetBuffer.byteCapacity) else {
                throw DecodedAudioImportError.encodingFailed
            }
            let packet = Data(bytes: packetBuffer.data.advanced(by: pktStart), count: pktCount)
            try writer.append(packet)
        }

        func emitSamples(_ ptr: UnsafePointer<Float>, count: Int, countTowardDuration: Bool) throws {
            guard count > 0 else { return }
            if countTowardDuration {
                let (nextTotal, overflow) = totalSamples48k.addingReportingOverflow(Int64(count))
                guard !overflow, nextTotal <= Int64(Int.max - preSkip - opusFrameSamples) else {
                    throw DecodedAudioImportError.encodingFailed
                }
                totalSamples48k = nextTotal
            }
            pending.append(contentsOf: UnsafeBufferPointer(start: ptr, count: count))
            while pending.count - pendingOffset >= opusFrameSamples {
                try encodeOneFrame(pending[pendingOffset..<(pendingOffset + opusFrameSamples)])
                pendingOffset += opusFrameSamples
            }
            if pendingOffset > 0 {
                pending.removeFirst(pendingOffset)
                pendingOffset = 0
            }
        }

        let scale = 1.0 / Float(channelCount)
        while true {
            if shouldCancel() { throw CancellationError() }
            readBuffer.frameLength = 0
            do {
                try inFile.read(into: readBuffer, frameCount: chunkCapacity)
            } catch {
                // If zero samples were decoded at all, fail; if we hit EOF on a normal MP3/AAC frame boundary after decoding audio, check position.
                if totalSamples48k == 0 || inFile.framePosition < inFile.length {
                    throw DecodedAudioImportError.unreadableAudio
                }
                break
            }
            let framesRead = Int(readBuffer.frameLength)
            if framesRead == 0 {
                break
            }
            guard let srcChannels = readBuffer.floatChannelData,
                  let monoDst = monoBuffer.floatChannelData?[0] else {
                throw DecodedAudioImportError.unreadableAudio
            }
            monoBuffer.frameLength = AVAudioFrameCount(framesRead)
            if channelCount == 1 {
                let ch0 = srcChannels[0]
                for i in 0..<framesRead {
                    let s = ch0[i]
                    monoDst[i] = s.isFinite ? max(-1.0, min(1.0, s)) : 0.0
                }
            } else {
                for i in 0..<framesRead {
                    var sum: Float = 0
                    for c in 0..<channelCount {
                        let s = srcChannels[c][i]
                        if s.isFinite { sum += s }
                    }
                    monoDst[i] = max(-1.0, min(1.0, sum * scale))
                }
            }

            if let resampler {
                let outCapacity = AVAudioFrameCount(ceil(Double(framesRead) * targetSampleRate / processingFormat.sampleRate) + 64)
                guard let outBuffer = AVAudioPCMBuffer(pcmFormat: pcm48Format, frameCapacity: outCapacity) else {
                    throw DecodedAudioImportError.encodingFailed
                }
                var supplied = false
                var resampleError: NSError?
                let status = resampler.convert(to: outBuffer, error: &resampleError) { _, outStatus in
                    if !supplied {
                        supplied = true
                        outStatus.pointee = .haveData
                        return monoBuffer
                    }
                    outStatus.pointee = .noDataNow
                    return nil
                }
                if resampleError != nil || status == .error {
                    throw DecodedAudioImportError.unreadableAudio
                }
                let outFrames = Int(outBuffer.frameLength)
                if outFrames > 0, let outPtr = outBuffer.floatChannelData?[0] {
                    try emitSamples(outPtr, count: outFrames, countTowardDuration: true)
                }
            } else {
                try emitSamples(monoDst, count: framesRead, countTowardDuration: true)
            }
        }

        if let resampler {
            guard let tailBuffer = AVAudioPCMBuffer(pcmFormat: pcm48Format, frameCapacity: 1024) else {
                throw DecodedAudioImportError.encodingFailed
            }
            while true {
                if shouldCancel() { throw CancellationError() }
                tailBuffer.frameLength = 0
                var resampleError: NSError?
                let status = resampler.convert(to: tailBuffer, error: &resampleError) { _, outStatus in
                    outStatus.pointee = .endOfStream
                    return nil
                }
                if resampleError != nil || status == .error {
                    throw DecodedAudioImportError.unreadableAudio
                }
                let outFrames = Int(tailBuffer.frameLength)
                if outFrames > 0, let outPtr = tailBuffer.floatChannelData?[0] {
                    try emitSamples(outPtr, count: outFrames, countTowardDuration: true)
                }
                if status == .endOfStream || outFrames == 0 {
                    break
                }
            }
        }

        guard totalSamples48k > 0 else {
            throw DecodedAudioImportError.emptyAudio
        }

        // Flush encoder lookahead (`preSkip`) and pad any partial trailing 20 ms frame with silence,
        // matching `MeetingFileExporter` so `OpusPacketWriter` writes an exact RFC 7845 final granule.
        if preSkip > 0 {
            let lookaheadZeros = [Float](repeating: 0, count: preSkip)
            try lookaheadZeros.withUnsafeBufferPointer { buf in
                if let base = buf.baseAddress {
                    try emitSamples(base, count: buf.count, countTowardDuration: false)
                }
            }
        }
        let remainder = pending.count - pendingOffset
        if remainder > 0 {
            let padCount = opusFrameSamples - remainder
            let padZeros = [Float](repeating: 0, count: padCount)
            try padZeros.withUnsafeBufferPointer { buf in
                if let base = buf.baseAddress {
                    try emitSamples(base, count: buf.count, countTowardDuration: false)
                }
            }
        }

        if shouldCancel() { throw CancellationError() }
        try writer.finish(sampleCount: Int(totalSamples48k))
    }

    private static func validateContainerHeader(at url: URL, typeID: String) throws {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw DecodedAudioImportError.unreadableAudio }
        defer { close(fd) }
        var header = [UInt8](repeating: 0, count: 16)
        let n = header.withUnsafeMutableBytes { raw -> Int in
            guard let base = raw.baseAddress else { return 0 }
            return Darwin.read(fd, base, 16)
        }
        guard n >= 4 else { throw DecodedAudioImportError.unreadableAudio }
        // Never allow native FLAC (`fLaC`) or Ogg (`OggS`) containers disguised as MP3/M4A/WAV.
        if header.starts(with: [0x66, 0x4C, 0x61, 0x43]) || header.starts(with: [0x4F, 0x67, 0x67, 0x53]) {
            throw DecodedAudioImportError.unsupportedFormat(typeID)
        }
        switch typeID {
        case "wav":
            guard n >= 12 else { throw DecodedAudioImportError.unreadableAudio }
            let magic = Array(header[0..<4])
            let wave = Array(header[8..<12])
            let isRIFF = magic == Array("RIFF".utf8) || magic == Array("RF64".utf8)
            guard isRIFF, wave == Array("WAVE".utf8) else {
                throw DecodedAudioImportError.unsupportedFormat("wav")
            }
        case "m4a":
            // Require ISO-BMFF `ftyp` box (excludes raw ADTS `.aac`, `.mp3`, `.wav`, or `.flac` renamed `.m4a`).
            guard n >= 12, Array(header[4..<8]) == Array("ftyp".utf8) else {
                throw DecodedAudioImportError.unsupportedFormat("m4a")
            }
            // Reject QuickTime `.mov` (`qt  `) and explicit video-only MP4 brands if no M4A/MP4 audio brand is used.
            let brand = Array(header[8..<12])
            if brand == Array("qt  ".utf8) {
                throw DecodedAudioImportError.unsupportedFormat("mov")
            }
        case "mp3":
            // Reject RIFF WAVE or ISO-BMFF MP4/M4A disguised as `.mp3`.
            if n >= 12, (Array(header[0..<4]) == Array("RIFF".utf8) || Array(header[4..<8]) == Array("ftyp".utf8)) {
                throw DecodedAudioImportError.unsupportedFormat("mp3")
            }
        default:
            throw DecodedAudioImportError.unsupportedFormat(typeID)
        }
    }

    private static func isAllowedAudioFormatID(_ formatID: AudioFormatID, for typeID: String) -> Bool {
        // Explicitly forbid FLAC (`kAudioFormatFLAC`) across all decoded paths until L-09 / D-938 resolves.
        if formatID == kAudioFormatFLAC {
            return false
        }
        switch typeID {
        case "mp3":
            return formatID == kAudioFormatMPEGLayer3
        case "m4a":
            switch formatID {
            case kAudioFormatMPEG4AAC,
                 kAudioFormatMPEG4AAC_HE,
                 kAudioFormatMPEG4AAC_LD,
                 kAudioFormatMPEG4AAC_ELD,
                 kAudioFormatMPEG4AAC_ELD_SBR,
                 kAudioFormatMPEG4AAC_ELD_V2,
                 kAudioFormatMPEG4AAC_HE_V2,
                 kAudioFormatMPEG4AAC_Spatial,
                 kAudioFormatMPEGD_USAC,
                 kAudioFormatAppleLossless:
                return true
            default:
                return false
            }
        case "wav":
            switch formatID {
            case kAudioFormatLinearPCM,
                 kAudioFormatULaw,
                 kAudioFormatALaw,
                 kAudioFormatMicrosoftGSM,
                 kAudioFormatDVIIntelIMA:
                return true
            default:
                return false
            }
        default:
            return false
        }
    }
}
