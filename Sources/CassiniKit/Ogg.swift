import Foundation

/// One Ogg page (RFC 3533 §6), with its body sliced out of the file.
struct OggPage {
    var headerType: UInt8
    var granule: Int64
    var serial: UInt32
    var sequence: UInt32
    var storedCRC: UInt32
    var computedCRC: UInt32
    var lacing: [UInt8]
    var bodyRange: Range<Int>

    var isContinuation: Bool { headerType & 0x01 != 0 }
    var isBOS: Bool { headerType & 0x02 != 0 }
    var isEOS: Bool { headerType & 0x04 != 0 }
}

enum OggError: Error, Equatable, CustomStringConvertible {
    case notOgg
    case truncated
    case badVersion
    case notOpus(String)
    case headerTooLarge

    var description: String {
        switch self {
        case .notOgg: return "not an Ogg file"
        case .truncated: return "the file ends inside an Ogg page or packet"
        case .badVersion: return "unsupported Ogg stream structure version"
        case .notOpus(let why): return "not Ogg Opus: \(why)"
        case .headerTooLarge: return "the OpusTags header is larger than 120 MB"
        }
    }
}

/// Little-endian reads over raw bytes. Callers bounds-check first.
extension UnsafeRawBufferPointer {
    @inline(__always) func u16(_ o: Int) -> UInt16 { UInt16(self[o]) | UInt16(self[o + 1]) << 8 }
    @inline(__always) func u32(_ o: Int) -> UInt32 {
        UInt32(self[o]) | UInt32(self[o + 1]) << 8 | UInt32(self[o + 2]) << 16 | UInt32(self[o + 3]) << 24
    }
    @inline(__always) func u64(_ o: Int) -> UInt64 { UInt64(u32(o)) | UInt64(u32(o + 4)) << 32 }
}

/// The Ogg page CRC: polynomial 0x04c11db7, init 0, no reflection, no final XOR.
enum OggCRC {
    static let table: [UInt32] = (0..<256).map { i in
        var r = UInt32(i) << 24
        for _ in 0..<8 { r = (r & 0x8000_0000) != 0 ? (r << 1) ^ 0x04C1_1DB7 : r << 1 }
        return r
    }

    static func checksum(_ bytes: UnsafeRawBufferPointer, range: Range<Int>, zeroing crcAt: Int) -> UInt32 {
        var crc: UInt32 = 0
        table.withUnsafeBufferPointer { t in
            for i in range {
                let b: UInt8 = (i >= crcAt && i < crcAt + 4) ? 0 : bytes[i]
                crc = (crc << 8) ^ t[Int(((crc >> 24) & 0xFF) ^ UInt32(b))]
            }
        }
        return crc
    }
}

/// Walks Ogg pages in a byte buffer.
struct OggPageReader {
    let bytes: UnsafeRawBufferPointer
    var offset = 0
    var verifyCRC: Bool

    init(_ bytes: UnsafeRawBufferPointer, verifyCRC: Bool) {
        self.bytes = bytes
        self.verifyCRC = verifyCRC
    }

    var atEnd: Bool { offset >= bytes.count }

    mutating func next() throws -> OggPage? {
        if atEnd { return nil }
        let o = offset
        guard o + 27 <= bytes.count else { throw OggError.truncated }
        guard bytes[o] == 0x4F, bytes[o + 1] == 0x67, bytes[o + 2] == 0x67, bytes[o + 3] == 0x53 else {
            throw OggError.notOgg
        }
        guard bytes[o + 4] == 0 else { throw OggError.badVersion }
        let nseg = Int(bytes[o + 26])
        guard o + 27 + nseg <= bytes.count else { throw OggError.truncated }
        var lacing = [UInt8](repeating: 0, count: nseg)
        var bodyLen = 0
        for i in 0..<nseg {
            lacing[i] = bytes[o + 27 + i]
            bodyLen += Int(lacing[i])
        }
        let bodyStart = o + 27 + nseg
        guard bodyStart + bodyLen <= bytes.count else { throw OggError.truncated }
        let end = bodyStart + bodyLen
        let crc = verifyCRC ? OggCRC.checksum(bytes, range: o..<end, zeroing: o + 22) : bytes.u32(o + 22)
        offset = end
        return OggPage(
            headerType: bytes[o + 5],
            granule: Int64(bitPattern: bytes.u64(o + 6)),
            serial: bytes.u32(o + 14),
            sequence: bytes.u32(o + 18),
            storedCRC: bytes.u32(o + 22),
            computedCRC: crc,
            lacing: lacing,
            bodyRange: bodyStart..<end
        )
    }
}

/// The two Opus header packets, reassembled across pages.
public struct OpusHeaders: Sendable {
    public var head: Data
    public var tags: Data
    public var serial: UInt32

    public var channels: Int { Int(head[head.startIndex + 9]) }
    public var preSkip: Int { Int(head[head.startIndex + 10]) | Int(head[head.startIndex + 11]) << 8 }
    public var inputSampleRate: Int {
        let s = head.startIndex
        return Int(head[s + 12]) | Int(head[s + 13]) << 8 | Int(head[s + 14]) << 16 | Int(head[s + 15]) << 24
    }
}

enum OpusHeaderReader {
    /// The largest OpusTags packet we will assemble (SPEC: a consumer MAY reject over 120 MB).
    static let maxTagsBytes = 120 * 1024 * 1024

    /// Reads OpusHead and the whole OpusTags packet from the first logical stream.
    static func read(_ data: Data) throws -> OpusHeaders {
        try data.withUnsafeBytes { raw in
            var reader = OggPageReader(raw, verifyCRC: false)
            var serial: UInt32?
            var packets: [Data] = []
            var partial = Data()
            while packets.count < 2, let page = try reader.next() {
                if serial == nil {
                    guard page.isBOS else { throw OggError.notOpus("first page is not a beginning of stream") }
                    serial = page.serial
                }
                guard page.serial == serial else { continue }
                var pos = page.bodyRange.lowerBound
                for lace in page.lacing {
                    partial.append(contentsOf: UnsafeRawBufferPointer(rebasing: raw[pos..<(pos + Int(lace))]))
                    pos += Int(lace)
                    if partial.count > maxTagsBytes { throw OggError.headerTooLarge }
                    if lace < 255 {
                        packets.append(partial)
                        partial = Data()
                        if packets.count == 2 { break }
                    }
                }
            }
            guard packets.count == 2 else { throw OggError.truncated }
            let head = packets[0]
            guard head.count >= 19, head.prefix(8) == Data("OpusHead".utf8) else {
                throw OggError.notOpus("first packet is not OpusHead")
            }
            guard packets[1].prefix(8) == Data("OpusTags".utf8) else {
                throw OggError.notOpus("second packet is not OpusTags")
            }
            return OpusHeaders(head: head, tags: packets[1], serial: serial!)
        }
    }
}
