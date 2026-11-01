// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import AVFoundation
import Darwin
import CassiniLibrary

/// Native checkpoint WAVs use physical complete frames, not a stale RIFF/data
/// size. Pull decoding/resampling retains at most one small mono batch per track.
final class PCMInput {
    let rate: Int
    let frameCount: Int64
    let outputFrames: Int64
    let offsetFrames: Int64
    var source: AudioEncodeSource { .init(codec:"pcm_s16le",sampleRate:rate,speechBitrateBps:nil,empty:frameCount < rate) }
    private let channels: Int
    private let stream: FileHandle
    private let monoFormat: AVAudioFormat
    private let outputFormat: AVAudioFormat
    private let converter: AVAudioConverter?
    private var inputRemaining: Int64
    private var outputRemaining: Int64
    private var buffered: [Float] = []
    private var bufferedAt = 0
    private var consumed: Int64 = 0
    /// D52 half-open ownership in 48 kHz timeline frames; nil keeps every sample.
    private var owned: [(Int64,Int64)]?
    convenience init(_ track: LibraryAudioTrack, ownership: OthersOwnership?) throws {
        try self.init(track)
        if let ownership, let start = track.startOffsetMs, frameCount > 0 {
            let end = start + Double(outputFrames)/48
            owned = ownership.owned(kind:track.sourceKind,startMs:start,endMs:end).map {
                (Int64(($0.0*48).rounded(.toNearestOrAwayFromZero)),Int64(($0.1*48).rounded(.toNearestOrAwayFromZero)))
            }
        }
    }
    init(_ track: LibraryAudioTrack) throws {
        let fd = open(track.url.path,O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw MeetingExportError.invalidSource }
        let handle = FileHandle(fileDescriptor:fd,closeOnDealloc:true)
        var info = stat()
        guard fstat(fd,&info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size >= 44 else { throw MeetingExportError.invalidSource }
        let header = try handle.read(upToCount:44) ?? Data()
        func u16(_ at: Int) -> Int { header.withUnsafeBytes { Int(UInt16(littleEndian:$0.loadUnaligned(fromByteOffset:at,as:UInt16.self))) } }
        func u32(_ at: Int) -> Int { header.withUnsafeBytes { Int(UInt32(littleEndian:$0.loadUnaligned(fromByteOffset:at,as:UInt32.self))) } }
        guard header.count == 44, header[0..<4] == Data("RIFF".utf8), header[8..<16] == Data("WAVEfmt ".utf8),
              header[36..<40] == Data("data".utf8), u32(16) == 16, u16(20) == 1, u16(34) == 16,
              [1,2].contains(u16(22)), (1000...384000).contains(u32(24)), u16(32) == u16(22) * 2 else { throw MeetingExportError.invalidSource }
        channels = u16(22); rate = u32(24); stream = handle
        frameCount = (info.st_size - 44) / Int64(channels * 2)
        let seconds = frameCount / Int64(rate), rest = frameCount % Int64(rate)
        let (whole,overflow) = seconds.multipliedReportingOverflow(by:48000)
        guard !overflow else { throw MeetingExportError.tooLarge }
        let (count,addOverflow) = whole.addingReportingOverflow((rest * 48000 + Int64(rate) - 1) / Int64(rate))
        guard !addOverflow else { throw MeetingExportError.tooLarge }; outputFrames = count
        if frameCount > 0 {
            let ms = track.startOffsetMs ?? 0 // D19: marked as assumed in export provenance.
            guard ms.isFinite, ms >= 0, ms <= 9_007_199_254_740_991 else { throw MeetingExportError.invalidSource }
            offsetFrames = Int64((ms * 48).rounded(.toNearestOrAwayFromZero))
        } else { offsetFrames = 0 }
        guard outputFrames <= Int64.max - offsetFrames - 960 else { throw MeetingExportError.tooLarge }
        inputRemaining = frameCount; outputRemaining = outputFrames
        guard let mono = AVAudioFormat(standardFormatWithSampleRate:Double(rate),channels:1),
              let out = AVAudioFormat(standardFormatWithSampleRate:48000,channels:1) else { throw MeetingExportError.invalidSource }
        monoFormat = mono; outputFormat = out
        if rate == 48000 { converter = nil }
        else {
            guard let converter = AVAudioConverter(from:mono,to:out) else { throw MeetingExportError.invalidSource }
            converter.primeMethod = .none; converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
            self.converter = converter
        }
    }
    deinit { try? stream.close() }
    func add(to output: inout [Float], position: Int64) throws {
        let start = max(position,offsetFrames), end = min(position + Int64(output.count),offsetFrames + outputFrames)
        guard end > start else { return }
        guard consumed == start - offsetFrames else { throw MeetingExportError.invalidSource }
        var destination = Int(start - position), left = Int(end - start)
        while left > 0 {
            if bufferedAt == buffered.count { buffered = try readOutput(); bufferedAt = 0 }
            let count = min(left,buffered.count - bufferedAt)
            guard count > 0 else { throw MeetingExportError.invalidSource }
            if let owned {
                // Samples outside this source's ownership are read but never mixed.
                for index in 0..<count {
                    let frame = position + Int64(destination + index)
                    if owned.contains(where:{ frame >= $0.0 && frame < $0.1 }) { output[destination + index] += buffered[bufferedAt + index] }
                }
            } else {
                for index in 0..<count { output[destination + index] += buffered[bufferedAt + index] }
            }
            bufferedAt += count; destination += count; left -= count; consumed += Int64(count)
        }
    }
    private func readMono(_ requested: Int) throws -> [Float] {
        let count = min(Int(inputRemaining),min(8192,requested))
        guard count > 0 else { return [] }
        let wanted = count * channels * 2
        var data = Data()
        while data.count < wanted {
            let part = try stream.read(upToCount:wanted - data.count) ?? Data()
            guard !part.isEmpty else { throw MeetingExportError.invalidSource }; data.append(part)
        }
        inputRemaining -= Int64(count)
        return data.withUnsafeBytes { bytes in
            (0..<count).map { frame in
                let at = frame * channels * 2
                let first = Float(Int16(littleEndian:bytes.loadUnaligned(fromByteOffset:at,as:Int16.self))) / 32768
                return channels == 1 ? first : (first + Float(Int16(littleEndian:bytes.loadUnaligned(fromByteOffset:at + 2,as:Int16.self))) / 32768) / 2
            }
        }
    }
    private func readOutput() throws -> [Float] {
        guard outputRemaining > 0 else { return [] }
        if converter == nil {
            let mono = try readMono(8192); outputRemaining -= Int64(mono.count); return mono
        }
        guard let converter, let output = AVAudioPCMBuffer(pcmFormat:outputFormat,frameCapacity:8192) else { throw MeetingExportError.invalidSource }
        var failed: Error?, error: NSError?
        let status = converter.convert(to:output,error:&error) { requested,state in
            do {
                let mono = try self.readMono(Int(requested))
                guard !mono.isEmpty else { state.pointee = .endOfStream; return nil }
                guard let input = AVAudioPCMBuffer(pcmFormat:self.monoFormat,frameCapacity:AVAudioFrameCount(mono.count)), let data = input.floatChannelData else { throw MeetingExportError.invalidSource }
                input.frameLength = AVAudioFrameCount(mono.count)
                mono.withUnsafeBufferPointer { data[0].update(from:$0.baseAddress!,count:mono.count) }
                state.pointee = .haveData; return input
            } catch { failed = error; state.pointee = .noDataNow; return nil }
        }
        if let failed { throw failed }
        if let error { throw error }
        guard status != .error else { throw MeetingExportError.invalidSource }
        if output.frameLength == 0 {
            // A converter can drain a fraction short of the integer timeline.
            // Only a clean EOF after all physical input permits silent padding.
            guard status == .endOfStream, inputRemaining == 0 else { throw MeetingExportError.invalidSource }
            let count = min(8192,Int(outputRemaining)); outputRemaining -= Int64(count)
            return [Float](repeating:0,count:count)
        }
        guard let data = output.floatChannelData else { throw MeetingExportError.invalidSource }
        let count = min(Int(outputRemaining),Int(output.frameLength)); outputRemaining -= Int64(count)
        return Array(UnsafeBufferPointer(start:data[0],count:count))
    }
}
