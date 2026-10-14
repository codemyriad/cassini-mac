import Foundation

/// A parsed JSON value. Objects keep member order and reject repeated names.
public enum JSON: Sendable, Equatable {
    case null
    case bool(Bool)
    /// The number's literal text, so integers stay exact.
    case number(String)
    case string(String)
    case array([JSON])
    case object([(String, JSON)])

    public static func == (a: JSON, b: JSON) -> Bool {
        switch (a, b) {
        case (.null, .null): return true
        case let (.bool(x), .bool(y)): return x == y
        case let (.number(x), .number(y)): return x == y
        case let (.string(x), .string(y)): return x == y
        case let (.array(x), .array(y)): return x == y
        case let (.object(x), .object(y)):
            return x.count == y.count && zip(x, y).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
        default: return false
        }
    }

    public subscript(key: String) -> JSON? {
        if case .object(let members) = self { return members.first { $0.0 == key }?.1 }
        return nil
    }

    public var string: String? { if case .string(let s) = self { return s }; return nil }
    public var bool: Bool? { if case .bool(let b) = self { return b }; return nil }
    public var array: [JSON]? { if case .array(let a) = self { return a }; return nil }
    public var object: [(String, JSON)]? { if case .object(let o) = self { return o }; return nil }
    public var isNull: Bool { if case .null = self { return true }; return false }

    /// An integer literal (no fraction or exponent) that fits in Int.
    public var int: Int? {
        guard case .number(let s) = self, !s.contains(where: { $0 == "." || $0 == "e" || $0 == "E" }) else { return nil }
        return Int(s)
    }

    public var double: Double? { if case .number(let s) = self { return Double(s) }; return nil }

    public var keys: [String] { object?.map(\.0) ?? [] }
}

/// A strict RFC 8259 parser: fatal on invalid UTF-8, repeated member names, or excessive depth.
public struct JSONParser {
    public static let maxDepth = 64

    public static func parse(_ data: Data) throws -> JSON {
        guard String(data: data, encoding: .utf8) != nil else { throw PayloadError.utf8 }
        return try data.withUnsafeBytes { raw in
            var p = JSONParser(bytes: raw)
            p.skipWS()
            let v = try p.value(depth: 0)
            p.skipWS()
            guard p.i == raw.count else { throw p.fail("trailing characters") }
            return v
        }
    }

    let bytes: UnsafeRawBufferPointer
    var i = 0

    func fail(_ why: String) -> PayloadError { .json("\(why) at byte \(i)") }

    mutating func skipWS() {
        while i < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[i]) { i += 1 }
    }

    mutating func expect(_ literal: String) throws {
        for c in literal.utf8 {
            guard i < bytes.count, bytes[i] == c else { throw fail("expected \(literal)") }
            i += 1
        }
    }

    mutating func value(depth: Int) throws -> JSON {
        guard depth < JSONParser.maxDepth else { throw fail("nesting deeper than \(JSONParser.maxDepth)") }
        guard i < bytes.count else { throw fail("unexpected end") }
        switch bytes[i] {
        case UInt8(ascii: "{"):
            i += 1
            var members: [(String, JSON)] = []
            var seen = Set<String>()
            skipWS()
            if i < bytes.count, bytes[i] == UInt8(ascii: "}") { i += 1; return .object(members) }
            while true {
                skipWS()
                guard i < bytes.count, bytes[i] == UInt8(ascii: "\"") else { throw fail("expected a member name") }
                let key = try string()
                guard seen.insert(key).inserted else { throw fail("repeated member \"\(key)\"") }
                skipWS()
                try expect(":")
                skipWS()
                members.append((key, try value(depth: depth + 1)))
                skipWS()
                guard i < bytes.count else { throw fail("unexpected end") }
                if bytes[i] == UInt8(ascii: ",") { i += 1; continue }
                if bytes[i] == UInt8(ascii: "}") { i += 1; return .object(members) }
                throw fail("expected , or }")
            }
        case UInt8(ascii: "["):
            i += 1
            var items: [JSON] = []
            skipWS()
            if i < bytes.count, bytes[i] == UInt8(ascii: "]") { i += 1; return .array(items) }
            while true {
                skipWS()
                items.append(try value(depth: depth + 1))
                skipWS()
                guard i < bytes.count else { throw fail("unexpected end") }
                if bytes[i] == UInt8(ascii: ",") { i += 1; continue }
                if bytes[i] == UInt8(ascii: "]") { i += 1; return .array(items) }
                throw fail("expected , or ]")
            }
        case UInt8(ascii: "\""): return .string(try string())
        case UInt8(ascii: "t"): try expect("true"); return .bool(true)
        case UInt8(ascii: "f"): try expect("false"); return .bool(false)
        case UInt8(ascii: "n"): try expect("null"); return .null
        default: return .number(try number())
        }
    }

    mutating func number() throws -> String {
        let start = i
        func digits() -> Int {
            let s = i
            while i < bytes.count, bytes[i] >= 0x30, bytes[i] <= 0x39 { i += 1 }
            return i - s
        }
        if i < bytes.count, bytes[i] == UInt8(ascii: "-") { i += 1 }
        guard i < bytes.count else { throw fail("bad number") }
        if bytes[i] == UInt8(ascii: "0") { i += 1 } else if digits() == 0 { throw fail("bad number") }
        if i < bytes.count, bytes[i] == UInt8(ascii: ".") {
            i += 1
            guard digits() > 0 else { throw fail("bad fraction") }
        }
        if i < bytes.count, bytes[i] == UInt8(ascii: "e") || bytes[i] == UInt8(ascii: "E") {
            i += 1
            if i < bytes.count, bytes[i] == UInt8(ascii: "+") || bytes[i] == UInt8(ascii: "-") { i += 1 }
            guard digits() > 0 else { throw fail("bad exponent") }
        }
        return String(decoding: UnsafeRawBufferPointer(rebasing: bytes[start..<i]), as: UTF8.self)
    }

    mutating func hex4() throws -> UInt32 {
        guard i + 4 <= bytes.count else { throw fail("bad \\u escape") }
        var v: UInt32 = 0
        for _ in 0..<4 {
            let c = bytes[i]
            let d: UInt32
            switch c {
            case 0x30...0x39: d = UInt32(c - 0x30)
            case 0x41...0x46: d = UInt32(c - 0x37)
            case 0x61...0x66: d = UInt32(c - 0x57)
            default: throw fail("bad \\u escape")
            }
            v = v << 4 | d
            i += 1
        }
        return v
    }

    mutating func string() throws -> String {
        i += 1  // opening quote
        var out = [UInt8]()
        while true {
            guard i < bytes.count else { throw fail("unterminated string") }
            let c = bytes[i]
            if c == UInt8(ascii: "\"") { i += 1; break }
            guard c >= 0x20 else { throw fail("control character in string") }
            if c != UInt8(ascii: "\\") { out.append(c); i += 1; continue }
            i += 1
            guard i < bytes.count else { throw fail("unterminated escape") }
            let e = bytes[i]; i += 1
            switch e {
            case UInt8(ascii: "\""): out.append(0x22)
            case UInt8(ascii: "\\"): out.append(0x5C)
            case UInt8(ascii: "/"): out.append(0x2F)
            case UInt8(ascii: "b"): out.append(0x08)
            case UInt8(ascii: "f"): out.append(0x0C)
            case UInt8(ascii: "n"): out.append(0x0A)
            case UInt8(ascii: "r"): out.append(0x0D)
            case UInt8(ascii: "t"): out.append(0x09)
            case UInt8(ascii: "u"):
                var scalar = try hex4()
                if (0xD800..<0xDC00).contains(scalar) {
                    guard i + 1 < bytes.count, bytes[i] == UInt8(ascii: "\\"), bytes[i + 1] == UInt8(ascii: "u") else {
                        throw fail("lone surrogate")
                    }
                    i += 2
                    let low = try hex4()
                    guard (0xDC00..<0xE000).contains(low) else { throw fail("lone surrogate") }
                    scalar = 0x10000 + ((scalar - 0xD800) << 10) + (low - 0xDC00)
                } else if (0xDC00..<0xE000).contains(scalar) {
                    throw fail("lone surrogate")
                }
                out.append(contentsOf: Array(String(Character(Unicode.Scalar(scalar)!)).utf8))
            default: throw fail("bad escape")
            }
        }
        return String(decoding: out, as: UTF8.self)
    }
}
