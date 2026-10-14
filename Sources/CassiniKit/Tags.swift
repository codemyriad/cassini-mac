import Foundation

/// One Vorbis comment as written in the file.
public struct Comment: Sendable, Hashable {
    /// The name as spelled in the file.
    public var name: String
    public var value: String
}

/// The OpusTags comment vector. Names compare with ASCII case folded; values compare exactly.
public struct TagSet: Sendable {
    public var vendor: String
    public var comments: [Comment]
    /// Upper-cased name to every value under it, in file order.
    private var index: [String: [String]] = [:]

    static let maxComments = 1_000_000

    public init(vendor: String, comments: [Comment]) {
        self.vendor = vendor
        self.comments = comments
        for c in comments {
            index[TagSet.fold(c.name), default: []].append(c.value)
        }
    }

    static func fold(_ name: String) -> String {
        String(String.UnicodeScalarView(name.unicodeScalars.map { s in
            (s.value >= 0x61 && s.value <= 0x7A) ? Unicode.Scalar(s.value - 32)! : s
        }))
    }

    /// The single value of a tag, or nil when absent. A repeated tag yields its first value;
    /// callers that care about repeats check `count(_:)`.
    public subscript(name: String) -> String? { index[TagSet.fold(name)]?.first }

    public func count(_ name: String) -> Int { index[TagSet.fold(name)]?.count ?? 0 }

    /// Upper-cased names that appear more than once.
    public var repeatedNames: [String] { index.filter { $0.value.count > 1 }.map(\.key).sorted() }

    /// Upper-cased names, unique.
    public var names: Dictionary<String, [String]>.Keys { index.keys }

    /// Parses an OpusTags packet (RFC 7845 §5.2), reading every comment.
    public static func parse(_ packet: Data) throws -> TagSet {
        try packet.withUnsafeBytes { b in
            var o = 8
            func need(_ n: Int) throws {
                guard n >= 0, o + n <= b.count else { throw OggError.notOpus("OpusTags packet is truncated") }
            }
            try need(4)
            let vlen = Int(b.u32(o)); o += 4
            try need(vlen)
            let vendor = String(decoding: UnsafeRawBufferPointer(rebasing: b[o..<(o + vlen)]), as: UTF8.self)
            o += vlen
            try need(4)
            let n = Int(b.u32(o)); o += 4
            guard n <= maxComments else { throw OggError.notOpus("OpusTags claims \(n) comments") }
            var comments: [Comment] = []
            comments.reserveCapacity(n)
            for _ in 0..<n {
                try need(4)
                let len = Int(b.u32(o)); o += 4
                try need(len)
                let bytes = UnsafeRawBufferPointer(rebasing: b[o..<(o + len)])
                o += len
                guard let eq = bytes.firstIndex(of: UInt8(ascii: "=")) else { continue }
                let name = String(decoding: UnsafeRawBufferPointer(rebasing: bytes[..<eq]), as: UTF8.self)
                let value = String(decoding: UnsafeRawBufferPointer(rebasing: bytes[(eq + 1)...]), as: UTF8.self)
                comments.append(Comment(name: name, value: value))
            }
            return TagSet(vendor: vendor, comments: comments)
        }
    }
}
