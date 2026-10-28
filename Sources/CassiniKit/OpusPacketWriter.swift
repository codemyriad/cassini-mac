// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Darwin

/// Bounded Ogg muxer. Audio pages contain up to 50 packets; the final batch is
/// retained until EOS so an exact page boundary still gets the final granule.
public final class OpusPacketWriter {
    private let stream: FileHandle
    private let serial: UInt32
    private let preSkip: Int
    private var sequence: UInt32 = 0
    private var codedSamples = 0
    private var pendingLacing: [UInt8] = []
    private var pendingBody = Data()
    private var pendingCount = 0
    private var finished = false
    public init(url: URL, head: Data, tags: Data) throws {
        guard url.isFileURL, head.count >= 19, head.prefix(8) == Data("OpusHead".utf8), tags.prefix(8) == Data("OpusTags".utf8) else { throw OggError.notOpus("invalid writer headers") }
        preSkip = Int(head[10]) | Int(head[11]) << 8
        serial = UInt32.random(in:1...UInt32.max)
        let fd = open(url.path,O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue:errno) ?? .EIO) }
        stream = FileHandle(fileDescriptor:fd,closeOnDealloc:true)
        do { try header(head,bos:true); try header(tags,bos:false) }
        catch { try? stream.close(); throw error }
    }
    deinit { try? stream.close() }
    public static func monoHead(preSkip: Int) throws -> Data {
        guard (0...65535).contains(preSkip) else { throw OggError.notOpus("invalid pre-skip") }
        var result = Data("OpusHead".utf8); result.append(contentsOf:[1,1])
        var skip = UInt16(preSkip).littleEndian, rate = UInt32(48000).littleEndian
        withUnsafeBytes(of:&skip) { result.append(contentsOf:$0) }; withUnsafeBytes(of:&rate) { result.append(contentsOf:$0) }
        result.append(contentsOf:[0,0,0]); return result
    }
    public func append(_ packet: Data) throws {
        guard !finished, packet.count <= 65024,
              let frames = packet.withUnsafeBytes({ OpusAudioDigest.packetSamples($0) }) else { throw OggError.notOpus("invalid audio packet") }
        let laces = Self.lacing(packet.count)
        if pendingCount == 50 || pendingLacing.count + laces.count > 255 { try flush(eos:false,granule:codedSamples) }
        pendingBody.append(packet); pendingLacing += laces; pendingCount += 1
        let (sum,overflow) = codedSamples.addingReportingOverflow(frames)
        guard !overflow else { throw OggError.notOpus("sample count overflow") }; codedSamples = sum
    }
    public func finish(sampleCount: Int) throws {
        guard !finished, sampleCount >= 0, sampleCount <= Int.max - preSkip,
              sampleCount + preSkip <= codedSamples, pendingCount > 0 else { throw AudioDigestError.invalidFinalGranule }
        try flush(eos:true,granule:sampleCount + preSkip)
        try stream.synchronize(); try stream.close(); finished = true
    }
    private static func lacing(_ length: Int) -> [UInt8] { [UInt8](repeating:255,count:length / 255) + [UInt8(length % 255)] }
    private func header(_ data: Data, bos: Bool) throws {
        let laces = Self.lacing(data.count)
        var offset = 0
        for start in stride(from:0,to:laces.count,by:255) {
            let part = Array(laces[start..<min(start + 255,laces.count)])
            let length = part.reduce(0) { $0 + Int($1) }, end = start + part.count == laces.count
            let flags: UInt8 = (bos && start == 0 ? 2 : 0) | (start > 0 ? 1 : 0)
            try page(laces:part,body:Data(data[offset..<offset + length]),flags:flags,granule:end ? 0 : -1)
            offset += length
        }
    }
    private func flush(eos: Bool, granule: Int) throws {
        try page(laces:pendingLacing,body:pendingBody,flags:eos ? 4 : 0,granule:Int64(granule))
        pendingLacing.removeAll(keepingCapacity:true); pendingBody.removeAll(keepingCapacity:true); pendingCount = 0
    }
    private func page(laces: [UInt8], body: Data, flags: UInt8, granule: Int64) throws {
        guard laces.count <= 255 else { throw OggError.truncated }
        var page = Data("OggS".utf8); page.append(contentsOf:[0,flags])
        func integer<T: FixedWidthInteger>(_ value: T) { var little = value.littleEndian; withUnsafeBytes(of:&little) { page.append(contentsOf:$0) } }
        integer(granule); integer(serial); integer(sequence); integer(UInt32(0))
        page.append(UInt8(laces.count)); page.append(contentsOf:laces); page.append(body)
        var crc = page.withUnsafeBytes { OggCRC.checksum($0,range:0..<$0.count,zeroing:22) }.littleEndian
        withUnsafeBytes(of:&crc) { page.replaceSubrange(22..<26,with:$0) }
        try stream.write(contentsOf:page)
        let (next,overflow) = sequence.addingReportingOverflow(1)
        guard !overflow else { throw OggError.notOpus("page sequence overflow") }; sequence = next
    }
}

public enum OpusStreamFile {
    /// Re-page with new tags; OpusHead and every compressed audio packet stay
    /// byte-identical, including an older stereo stream (D13).
    public static func rewrite(_ data: Data, tags: Data, to url: URL, shouldCancel: () -> Bool = { false }) throws -> AudioDigest {
        let digest = try OpusAudioDigest.compute(data)
        let head = try firstPacket(data)
        let writer = try OpusPacketWriter(url:url,head:head,tags:tags)
        try packets(data) { index,packet in
            if shouldCancel() { throw CancellationError() }
            if index >= 2 { try writer.append(packet) }
        }
        try writer.finish(sampleCount:digest.sampleCount); return digest
    }
    public static func packetBitrateHistogram(_ data: Data) throws -> (histogram: [Int:Int], packetCount: Int) {
        _ = try OpusAudioDigest.compute(data)
        var histogram: [Int:Int] = [:], count = 0
        try packets(data) { index,packet in
            guard index >= 2 else { return }; count += 1
            guard let samples = packet.withUnsafeBytes({ OpusAudioDigest.packetSamples($0) }) else { throw AudioDigestError.malformedPacket(index,"duration") }
            let channels = packet[0] & 4 == 0 ? 1 : 2
            let rate = Int((Double(packet.count) * 8 * 48000 / Double(samples) / Double(channels)).rounded(.toNearestOrAwayFromZero))
            histogram[rate,default:0] += 1
        }
        return (histogram,count)
    }
    private static func packets(_ data: Data, consume: (Int,Data) throws -> Void) throws {
        try data.withUnsafeBytes { bytes in
            var reader = OggPageReader(bytes,verifyCRC:false), index = 0, partial = Data()
            while let page = try reader.next() {
                var offset = page.bodyRange.lowerBound
                for lace in page.lacing {
                    let count = Int(lace)
                    // The potentially large old tags are not retained here.
                    if index != 1 { partial.append(bytes.baseAddress!.advanced(by:offset).assumingMemoryBound(to:UInt8.self),count:count) }
                    offset += count
                    if lace < 255 { try consume(index,partial); partial.removeAll(keepingCapacity:true); index += 1 }
                }
            }
        }
    }
    private static func firstPacket(_ data: Data) throws -> Data {
        try data.withUnsafeBytes { bytes in
            var reader = OggPageReader(bytes,verifyCRC:false), partial = Data()
            while let page = try reader.next() {
                var offset = page.bodyRange.lowerBound
                for lace in page.lacing {
                    let count = Int(lace)
                    guard partial.count + count <= 4096 else { throw OggError.headerTooLarge }
                    partial.append(bytes.baseAddress!.advanced(by:offset).assumingMemoryBound(to:UInt8.self),count:count)
                    offset += count
                    if lace < 255 { return partial }
                }
            }
            throw OggError.truncated
        }
    }
}
