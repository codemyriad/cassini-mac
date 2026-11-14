// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import AudioToolbox
import CassiniKit
import CryptoKit
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

/// Offline audio decoder and Ogg Opus muxer for `MP3`, `M4A`, `WAV`, and native `FLAC` imports (`L-25` / `D-1028`).
/// Streams PCM in bounded chunks, mixes multichannel audio to mono 48 kHz Float32, and encodes
/// 20 ms (960-sample) Opus packets via software `AVAudioConverter` without opening any audio device.
enum DecodedAudioImport {
    private static let chunkCapacity: AVAudioFrameCount = 8_192
    private static let opusFrameSamples = 960
    private static let targetSampleRate: Double = 48_000
    private static let targetBitrateBps = 64_000

    static func requiresTranscode(typeID: String) -> Bool {
        switch typeID {
        case "mp3", "m4a", "wav", "flac":
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

        let flacInfo = try validateContainerHeader(at: sourceURL, typeID: typeID, shouldCancel: shouldCancel)

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
              (inFile.length > 0 || flacInfo != nil) else {
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
        var decodedSourceFrames: Int64 = 0

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
            // Do not issue an extra EOF read: Core Audio throws eofErr even for
            // valid FLAC. The packet scan supplies an independently checked end.
            if let flacInfo, decodedSourceFrames == flacInfo.frameSamples { break }
            let requested = flacInfo.map { AVAudioFrameCount(min(Int64(chunkCapacity), $0.frameSamples - decodedSourceFrames)) } ?? chunkCapacity
            readBuffer.frameLength = 0
            do {
                try inFile.read(into: readBuffer, frameCount: requested)
            } catch {
                // If zero samples were decoded at all, fail; if we hit EOF on a normal MP3/AAC frame boundary after decoding audio, check position.
                if typeID == "flac" || totalSamples48k == 0 || inFile.framePosition < inFile.length {
                    throw DecodedAudioImportError.unreadableAudio
                }
                break
            }
            let framesRead = Int(readBuffer.frameLength)
            decodedSourceFrames += Int64(framesRead)
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

        if let flacInfo {
            guard decodedSourceFrames > 0, decodedSourceFrames == flacInfo.frameSamples else {
                throw DecodedAudioImportError.unreadableAudio
            }
            if flacInfo.totalSamples > 0 {
                guard decodedSourceFrames == flacInfo.totalSamples else {
                    throw DecodedAudioImportError.unreadableAudio
                }
            } else {
                guard inFile.framePosition >= inFile.length else {
                    throw DecodedAudioImportError.unreadableAudio
                }
                try verifyUnknownLengthFlac(at: sourceURL, info: flacInfo,
                    decodedFrames: decodedSourceFrames, shouldCancel: shouldCancel)
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

    private struct FlacInfo {
        let totalSamples: Int64
        let frameSamples: Int64
        let bitsPerSample: Int
        let md5: Data
    }

    // FLAC has no end marker. CRC-16 detects a partial final frame; when the
    // sample count is unknown, the PCM MD5 is also needed to detect whole-frame loss.
    private static func validateFlac(at url: URL, shouldCancel: () -> Bool) throws -> FlacInfo {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let bytes = [UInt8](try file.read(upToCount: 42) ?? Data())
        guard bytes.count == 42 else { throw DecodedAudioImportError.unreadableAudio }
        let samples = (Int64(bytes[21] & 0x0F) << 32) | (Int64(bytes[22]) << 24)
            | (Int64(bytes[23]) << 16) | (Int64(bytes[24]) << 8) | Int64(bytes[25])
        var lastMetadata = bytes[4] & 0x80 != 0
        while !lastMetadata {
            if shouldCancel() { throw CancellationError() }
            let header = [UInt8](try file.read(upToCount: 4) ?? Data())
            guard header.count == 4 else { throw DecodedAudioImportError.unreadableAudio }
            lastMetadata = header[0] & 0x80 != 0
            var remaining = Int(header[1]) << 16 | Int(header[2]) << 8 | Int(header[3])
            while remaining > 0 {
                if shouldCancel() { throw CancellationError() }
                let block = try file.read(upToCount: min(remaining, 65_536)) ?? Data()
                guard !block.isEmpty else { throw DecodedAudioImportError.unreadableAudio }
                remaining -= block.count
            }
        }
        let audioStart = try file.offset()
        let fileSize = try file.seekToEnd()
        var audioFile: AudioFileID?
        guard AudioFileOpenURL(url as CFURL, .readPermission, kAudioFileFLACType, &audioFile) == noErr,
              let audioFile else { throw DecodedAudioImportError.unreadableAudio }
        defer { AudioFileClose(audioFile) }
        var packets: UInt64 = 0
        var propertySize = UInt32(MemoryLayout<UInt64>.size)
        guard AudioFileGetProperty(audioFile, kAudioFilePropertyAudioDataPacketCount, &propertySize, &packets) == noErr,
              packets > 0, packets <= UInt64(Int64.max) else { throw DecodedAudioImportError.unreadableAudio }
        var maxPacket: UInt32 = 0
        propertySize = UInt32(MemoryLayout<UInt32>.size)
        guard AudioFileGetProperty(audioFile, kAudioFilePropertyPacketSizeUpperBound, &propertySize, &maxPacket) == noErr,
              maxPacket > 0, maxPacket <= 4_194_304 else { throw DecodedAudioImportError.unreadableAudio }
        var packet = [UInt8](repeating: 0, count: Int(maxPacket))
        var audioBytes: UInt64 = 0
        var frameSamples: Int64 = 0
        for index in 0..<packets {
            if shouldCancel() { throw CancellationError() }
            var size = maxPacket
            var count: UInt32 = 1
            var description = AudioStreamPacketDescription()
            guard AudioFileReadPacketData(audioFile, false, &size, &description, Int64(index), &count, &packet) == noErr,
                  count == 1, size >= 8, size <= maxPacket,
                  packet[0] == 0xff, packet[1] & 0xfe == 0xf8 else {
                throw DecodedAudioImportError.unreadableAudio
            }
            var crc: UInt16 = 0
            for byte in packet.prefix(Int(size)) {
                crc = (crc &<< 8) ^ flacCRCTable[Int((crc >> 8) ^ UInt16(byte))]
            }
            guard crc == 0 else { throw DecodedAudioImportError.unreadableAudio }
            let numberBytes = packet[4] < 0x80 ? 1 : (~packet[4]).leadingZeroBitCount
            guard (1...7).contains(numberBytes) else { throw DecodedAudioImportError.unreadableAudio }
            let blockOffset = 4 + numberBytes
            guard blockOffset + 2 < Int(size) else { throw DecodedAudioImportError.unreadableAudio }
            let blockSamples: Int64
            switch packet[2] >> 4 {
            case 1: blockSamples = 192
            case 2...5: blockSamples = 576 << Int((packet[2] >> 4) - 2)
            case 6: blockSamples = Int64(packet[blockOffset]) + 1
            case 7: blockSamples = (Int64(packet[blockOffset]) << 8 | Int64(packet[blockOffset + 1])) + 1
            case 8...15: blockSamples = 256 << Int((packet[2] >> 4) - 8)
            default: throw DecodedAudioImportError.unreadableAudio
            }
            let (next, overflow) = frameSamples.addingReportingOverflow(blockSamples)
            guard !overflow else { throw DecodedAudioImportError.unreadableAudio }
            frameSamples = next
            audioBytes += UInt64(size)
        }
        guard audioStart < fileSize, audioBytes == fileSize - audioStart,
              samples == 0 || frameSamples == samples else { throw DecodedAudioImportError.unreadableAudio }
        return FlacInfo(totalSamples: samples, frameSamples: frameSamples,
            bitsPerSample: Int((bytes[20] & 1) << 4 | (bytes[21] >> 4)) + 1,
            md5: Data(bytes[26..<42]))
    }

    private static let flacCRCTable: [UInt16] = (0..<256).map { byte in
        var crc = UInt16(byte) << 8
        for _ in 0..<8 { crc = crc & 0x8000 != 0 ? (crc &<< 1) ^ 0x8005 : crc &<< 1 }
        return crc
    }

    private static func verifyUnknownLengthFlac(
        at url: URL, info: FlacInfo, decodedFrames: Int64, shouldCancel: () -> Bool
    ) throws {
        // Without either a total or a digest, a boundary-truncated stream is
        // indistinguishable from a complete stream. Fail closed in that case.
        guard info.md5.contains(where: { $0 != 0 }) else {
            throw DecodedAudioImportError.unreadableAudio
        }
        do {
            // Integer PCM preserves all 32 FLAC bits; Float32 cannot do so.
            let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatInt32, interleaved: false)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunkCapacity) else {
                throw DecodedAudioImportError.unreadableAudio
            }
            var hash = Insecure.MD5()
            var frames: Int64 = 0
            let channels = Int(file.processingFormat.channelCount)
            let byteCount = (info.bitsPerSample + 7) / 8
            while frames < decodedFrames {
                if shouldCancel() { throw CancellationError() }
                let requested = AVAudioFrameCount(min(Int64(chunkCapacity), decodedFrames - frames))
                try file.read(into: buffer, frameCount: requested)
                guard buffer.frameLength > 0 else { throw DecodedAudioImportError.unreadableAudio }
                frames += Int64(buffer.frameLength)
                guard let pcm = buffer.int32ChannelData else { throw DecodedAudioImportError.unreadableAudio }
                var bytes = Data(capacity: Int(buffer.frameLength) * channels * byteCount)
                for frame in 0..<Int(buffer.frameLength) {
                    for channel in 0..<channels {
                        let sample = pcm[channel][frame] >> (32 - info.bitsPerSample)
                        for byte in 0..<byteCount {
                            bytes.append(UInt8(truncatingIfNeeded: sample >> (byte * 8)))
                        }
                    }
                }
                hash.update(data: bytes)
            }
            guard frames == decodedFrames, frames > 0, file.framePosition >= file.length,
                  Data(hash.finalize()) == info.md5 else { throw DecodedAudioImportError.unreadableAudio }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw DecodedAudioImportError.unreadableAudio
        }
    }

    private static func validateContainerHeader(
        at url: URL, typeID: String, shouldCancel: () -> Bool
    ) throws -> FlacInfo? {
        if typeID == "flac" {
            guard ImportTypesContract.shared.validateFile(at: url, fileNameOverride: "source.flac").typeID == "flac" else {
                throw DecodedAudioImportError.unsupportedFormat(typeID)
            }
            return try validateFlac(at: url, shouldCancel: shouldCancel)
        }
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
        return nil
    }

    private static func isAllowedAudioFormatID(_ formatID: AudioFormatID, for typeID: String) -> Bool {
        switch typeID {
        case "flac":
            return formatID == kAudioFormatFLAC
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
