import CryptoKit
import Foundation
import zlib

enum PayloadError: Error, Equatable, CustomStringConvertible {
    case base64(String)
    case gzip(String)
    case tooLarge(Int)
    case utf8
    case json(String)

    var description: String {
        switch self {
        case .base64(let why): return "base64url decode failed: \(why)"
        case .gzip(let why): return "gzip decode failed: \(why)"
        case .tooLarge(let n): return "decompressed payload exceeds \(n) bytes"
        case .utf8: return "payload is not valid UTF-8"
        case .json(let why): return "payload is not valid JSON: \(why)"
        }
    }
}

/// Strict base64url (RFC 4648 §5): padding optional, ASCII whitespace ignored, non-zero trailing bits rejected.
enum Base64URL {
    static let decodeTable: [Int8] = {
        var t = [Int8](repeating: -1, count: 256)
        for (i, c) in "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_".utf8.enumerated() {
            t[Int(c)] = Int8(i)
        }
        return t
    }()

    static func decode(_ text: String) throws -> Data {
        var symbols: [UInt8] = []
        symbols.reserveCapacity(text.utf8.count)
        var padding = 0
        for c in text.utf8 {
            switch c {
            case 0x20, 0x09, 0x0D, 0x0A: continue
            case UInt8(ascii: "="): padding += 1
            default:
                guard padding == 0 else { throw PayloadError.base64("padding before the end") }
                let v = decodeTable[Int(c)]
                guard v >= 0 else { throw PayloadError.base64("byte 0x\(String(c, radix: 16)) is outside the alphabet") }
                symbols.append(UInt8(v))
            }
        }
        let rem = symbols.count % 4
        guard rem != 1 else { throw PayloadError.base64("impossible length") }
        if padding > 0 {
            guard rem != 0, padding == 4 - rem else { throw PayloadError.base64("wrong amount of padding") }
        }
        var out = Data(capacity: symbols.count * 3 / 4)
        var i = 0
        while i + 4 <= symbols.count {
            let n = UInt32(symbols[i]) << 18 | UInt32(symbols[i + 1]) << 12 | UInt32(symbols[i + 2]) << 6 | UInt32(symbols[i + 3])
            out.append(UInt8(n >> 16)); out.append(UInt8((n >> 8) & 0xFF)); out.append(UInt8(n & 0xFF))
            i += 4
        }
        if rem == 2 {
            guard symbols[i + 1] & 0x0F == 0 else { throw PayloadError.base64("non-zero trailing bits") }
            out.append(symbols[i] << 2 | symbols[i + 1] >> 4)
        } else if rem == 3 {
            guard symbols[i + 2] & 0x03 == 0 else { throw PayloadError.base64("non-zero trailing bits") }
            let n = UInt32(symbols[i]) << 18 | UInt32(symbols[i + 1]) << 12 | UInt32(symbols[i + 2]) << 6
            out.append(UInt8(n >> 16)); out.append(UInt8((n >> 8) & 0xFF))
        }
        return out
    }
}

/// One gzip member (RFC 1952), inflated with a hard output bound.
enum Gzip {
    static func inflate(_ input: Data, limit: Int) throws -> Data {
        guard input.count >= 18, input[input.startIndex] == 0x1F, input[input.startIndex + 1] == 0x8B else {
            throw PayloadError.gzip("missing gzip header")
        }
        var stream = z_stream()
        // 16 + MAX_WBITS: gzip wrapper, header and CRC-32/ISIZE trailer checked by zlib.
        guard inflateInit2_(&stream, 16 + MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw PayloadError.gzip("zlib init failed")
        }
        defer { inflateEnd(&stream) }
        var output = Data()
        let chunk = 64 * 1024
        var buffer = [UInt8](repeating: 0, count: chunk)
        var status: Int32 = Z_OK
        var leftover = 0
        try input.withUnsafeBytes { (src: UnsafeRawBufferPointer) in
            stream.next_in = UnsafeMutablePointer(mutating: src.bindMemory(to: Bytef.self).baseAddress!)
            stream.avail_in = uInt(src.count)
            repeat {
                status = buffer.withUnsafeMutableBufferPointer { dst in
                    stream.next_out = dst.baseAddress
                    stream.avail_out = uInt(chunk)
                    return zlib.inflate(&stream, Z_NO_FLUSH)
                }
                let produced = chunk - Int(stream.avail_out)
                if output.count + produced > limit { throw PayloadError.tooLarge(limit) }
                output.append(contentsOf: buffer[0..<produced])
                if status == Z_BUF_ERROR && stream.avail_in == 0 { throw PayloadError.gzip("truncated stream") }
                guard status == Z_OK || status == Z_STREAM_END else {
                    let msg = stream.msg.map { String(cString: $0) } ?? "error \(status)"
                    throw PayloadError.gzip(msg)
                }
            } while status != Z_STREAM_END
            leftover = Int(stream.avail_in)
        }
        guard leftover == 0 else { throw PayloadError.gzip("\(leftover) bytes after the gzip member") }
        return output
    }
}

enum Hex {
    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// A decimal tag value: `0|[1-9][0-9]*`, at most 2^53−1.
func parseDecimal(_ s: String?) -> Int? {
    guard let s, !s.isEmpty, s.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }) else { return nil }
    if s.count > 1 && s.hasPrefix("0") { return nil }
    guard s.count <= 16, let v = Int(s), v <= (1 << 53) - 1 else { return nil }
    return v
}
