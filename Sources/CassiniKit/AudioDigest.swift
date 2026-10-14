import CryptoKit
import Foundation

/// The result of `exact-opus-audio-v1` over a file's compressed audio.
public struct AudioDigest: Sendable, Equatable {
    public var sha256: String
    public var channels: Int
    public var preSkip: Int
    public var sampleCount: Int
    public var packetCount: Int
    public var durationMs: Int { sampleCount * 1000 / 48000 }
}

public enum AudioDigestError: Error, Equatable, CustomStringConvertible {
    case container(String)
    case malformedHead(String)
    case malformedPacket(Int, String)
    case crc(page: Int)
    case sequenceGap(page: Int)
    case badContinuation(page: Int)
    case multiplexed
    case chained
    case truncatedPacket
    case missingEOS
    case invalidFinalGranule
    case tooShort

    public var description: String {
        switch self {
        case .container(let why): return why
        case .malformedHead(let why): return "malformed OpusHead: \(why)"
        case .malformedPacket(let n, let why): return "audio packet \(n) is malformed: \(why)"
        case .crc(let p): return "page \(p) fails its CRC"
        case .sequenceGap(let p): return "page sequence gap at page \(p)"
        case .badContinuation(let p): return "page \(p) has an invalid continuation flag"
        case .multiplexed: return "the file multiplexes more than one logical stream"
        case .chained: return "the file chains more than one logical stream"
        case .truncatedPacket: return "the last packet is truncated"
        case .missingEOS: return "the last page lacks the end-of-stream flag"
        case .invalidFinalGranule: return "the final granule position is invalid"
        case .tooShort: return "the audio is shorter than its pre-skip"
        }
    }
}

public enum OpusAudioDigest {
    static let domain = Data("org.cassini.opus-packets/1".utf8) + Data([0])

    /// Samples at 48 kHz in one Opus packet, from its TOC byte (RFC 6716 §3.1). nil when malformed.
    static func packetSamples(_ p: UnsafeRawBufferPointer) -> Int? {
        guard p.count >= 1 else { return nil }
        let toc = p[0]
        let config = Int(toc >> 3)
        let frame: Int  // in units of 120 samples (2.5 ms)
        switch config {
        case 0...11: frame = [4, 8, 16, 24][config % 4]
        case 12...15: frame = [4, 8][config % 2]
        default: frame = [1, 2, 4, 8][config % 4]
        }
        let frames: Int
        switch toc & 0x03 {
        case 0: frames = 1
        case 1, 2: frames = 2
        default:
            guard p.count >= 2 else { return nil }
            frames = Int(p[1] & 0x3F)
            guard frames > 0 else { return nil }
        }
        let samples = frame * 120 * frames
        guard samples <= 5760 else { return nil }  // 120 ms
        return samples
    }

    /// Computes the digest over a whole file. Throws when the stream cannot be digested.
    public static func compute(_ data: Data) throws -> AudioDigest {
        try data.withUnsafeBytes { raw in
            var reader = OggPageReader(raw, verifyCRC: true)
            var hasher = SHA256()
            hasher.update(data: domain)

            var serial: UInt32?
            var expectedSeq: UInt32 = 0
            var pageIndex = 0
            var packetIndex = 0  // 0 = OpusHead, 1 = OpusTags, then audio
            var partial: [UInt8] = []
            var pending = false
            var sawEOS = false
            var lastGranule: Int64 = 0
            var preSkip = 0
            var channels = 0
            var sum = 0
            var audioPackets = 0

            func finish(_ packet: UnsafeRawBufferPointer) throws {
                defer { packetIndex += 1 }
                if packetIndex == 0 {
                    guard packet.count >= 19 else { throw AudioDigestError.malformedHead("shorter than 19 bytes") }
                    guard Data(UnsafeRawBufferPointer(rebasing: packet[0..<8])) == Data("OpusHead".utf8) else {
                        throw AudioDigestError.malformedHead("wrong magic")
                    }
                    guard packet[8] <= 15 else { throw AudioDigestError.malformedHead("version \(packet[8])") }
                    channels = Int(packet[9])
                    guard channels == 1 || channels == 2 else {
                        throw AudioDigestError.malformedHead("\(channels) channels")
                    }
                    preSkip = Int(packet.u16(10))
                    var head = [UInt8](packet)
                    head[12] = 0; head[13] = 0; head[14] = 0; head[15] = 0
                    hasher.update(data: Data([UInt8(ascii: "H")]))
                    hasher.update(data: le64(UInt64(head.count)))
                    hasher.update(data: head)
                } else if packetIndex >= 2 {
                    guard let n = packetSamples(packet) else {
                        throw AudioDigestError.malformedPacket(audioPackets, packet.isEmpty ? "empty" : "bad TOC")
                    }
                    sum += n
                    audioPackets += 1
                    hasher.update(data: Data([UInt8(ascii: "A")]))
                    hasher.update(data: le64(UInt64(packet.count)))
                    hasher.update(bufferPointer: packet)
                }
            }

            do {
                while let page = try reader.next() {
                    defer { pageIndex += 1 }
                    if page.storedCRC != page.computedCRC { throw AudioDigestError.crc(page: pageIndex) }
                    if serial == nil {
                        guard page.isBOS else { throw AudioDigestError.container("first page is not BOS") }
                        serial = page.serial
                        expectedSeq = page.sequence
                    } else if page.serial != serial {
                        throw page.isBOS && sawEOS ? AudioDigestError.chained : AudioDigestError.multiplexed
                    } else if page.isBOS || sawEOS {
                        throw AudioDigestError.chained
                    }
                    guard page.sequence == expectedSeq else { throw AudioDigestError.sequenceGap(page: pageIndex) }
                    expectedSeq &+= 1
                    guard page.isContinuation == pending else { throw AudioDigestError.badContinuation(page: pageIndex) }

                    var pos = page.bodyRange.lowerBound
                    for lace in page.lacing {
                        let seg = UnsafeRawBufferPointer(rebasing: raw[pos..<(pos + Int(lace))])
                        pos += Int(lace)
                        if lace == 255 {
                            partial.append(contentsOf: seg)
                            pending = true
                            continue
                        }
                        if pending {
                            partial.append(contentsOf: seg)
                            try partial.withUnsafeBytes { try finish($0) }
                            partial.removeAll(keepingCapacity: true)
                            pending = false
                        } else {
                            try finish(seg)
                        }
                    }
                    lastGranule = page.granule
                    if page.isEOS { sawEOS = true }
                }
            } catch let e as OggError {
                throw AudioDigestError.container(e.description)
            }

            guard serial != nil, packetIndex >= 2 else { throw AudioDigestError.container("no Opus headers") }
            guard !pending else { throw AudioDigestError.truncatedPacket }
            guard sawEOS else { throw AudioDigestError.missingEOS }
            guard lastGranule >= 0, lastGranule >= Int64(preSkip) else { throw AudioDigestError.invalidFinalGranule }
            guard sum >= preSkip else { throw AudioDigestError.tooShort }
            let sampleCount = min(sum - preSkip, Int(lastGranule) - preSkip)

            hasher.update(data: Data([UInt8(ascii: "E")]))
            hasher.update(data: le64(UInt64(audioPackets)))
            hasher.update(data: le64(UInt64(sampleCount)))
            let hex = hasher.finalize().map { String(format: "%02x", $0) }.joined()
            return AudioDigest(sha256: hex, channels: channels, preSkip: preSkip, sampleCount: sampleCount,
                               packetCount: audioPackets)
        }
    }

    static func le64(_ v: UInt64) -> Data {
        withUnsafeBytes(of: v.littleEndian) { Data($0) }
    }
}
