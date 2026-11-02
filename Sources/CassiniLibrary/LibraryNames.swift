// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// S-12 §2 Library v2 file names with the §11 answers: a port of the coordination
/// reference `ux-draft/library-v2/names.py`, checked against its name vectors. Text is
/// handled as Unicode scalars, as the reference handles code points.
/// A name is `<prefix><title><suffix>.opus`, at most 200 UTF-8 bytes.
public enum LibraryNames {
    public static let maxBytes = 200
    public static let fileExtension = ".opus"
    static let prefixBytes = "YYYY-MM-DD--HH.MM-".utf8.count
    static let maxNonStarters = 30

    public enum Start: Sendable, Equatable {
        /// A namePrefix chosen earlier: kept forever, never recomputed.
        case persisted(String)
        /// A capture start (RFC 3339 UTC with `Z`), with its recorded UTC offset when valid;
        /// otherwise the Library device's zone at first conversion.
        case capture(startUtc: String, utcOffsetMinutes: Int?, libraryTimeZone: String?)
        /// A salvaged session without a start instant (Q16): the import instant.
        case unknownStart(importUtc: String, libraryTimeZone: String)
        /// A received file: its DATE tag when complete with an explicit offset, else the import instant.
        case received(dateTag: String?, importUtc: String, libraryTimeZone: String)
    }
    public struct Prefix: Sendable, Equatable {
        public let namePrefix: String
        public let utcOffsetMinutes: Int?
        /// recorded | legacy-device-tz | date-tag | import-time, or persisted (never stored).
        public let source: String
    }
    public enum NameError: Error, Equatable { case invalidStart, invalidPrefix, unknownZone }

    // MARK: prefix

    public static func validOffset(_ minutes: Int?) -> Bool { minutes.map { (-720...840).contains($0) } ?? false }
    public static func isPrefix(_ value: String) -> Bool {
        value.range(of:#"^[0-9]{4}-[0-9]{2}-[0-9]{2}--[0-9]{2}\.[0-9]{2}-$"#,options:.regularExpression) != nil
    }
    public static func prefix(_ start: Start) throws -> Prefix {
        switch start {
        case .persisted(let value):
            guard isPrefix(value) else { throw NameError.invalidPrefix }
            return .init(namePrefix:value,utcOffsetMinutes:nil,source:"persisted")
        case .capture(let startUtc,let offset,let zone):
            if validOffset(offset), let offset {
                return .init(namePrefix:try format(parseUTC(startUtc),zone:TimeZone(secondsFromGMT:offset*60)),utcOffsetMinutes:offset,source:"recorded")
            }
            guard let zone else { throw NameError.unknownZone }
            let (value,minutes) = try zoned(startUtc,zone)
            return .init(namePrefix:value,utcOffsetMinutes:minutes,source:"legacy-device-tz")
        case .unknownStart(let importUtc,let zone):
            let (value,minutes) = try zoned(importUtc,zone)
            return .init(namePrefix:value,utcOffsetMinutes:minutes,source:"import-time")
        case .received(let tag,let importUtc,let zone):
            if let tag, let parts = dateTag(tag) {
                return .init(namePrefix:parts.prefix,utcOffsetMinutes:parts.offset,source:"date-tag")
            }
            let (value,minutes) = try zoned(importUtc,zone)
            return .init(namePrefix:value,utcOffsetMinutes:minutes,source:"import-time")
        }
    }
    public static func parseUTC(_ value: String) throws -> Date {
        let pattern = #"^([0-9]{4})-([0-9]{2})-([0-9]{2})T([0-9]{2}):([0-9]{2}):([0-9]{2})(\.[0-9]{1,6})?Z$"#
        guard let match = try NSRegularExpression(pattern:pattern).firstMatch(in:value,range:NSRange(value.startIndex...,in:value)) else { throw NameError.invalidStart }
        func group(_ i: Int) -> String? { Range(match.range(at:i),in:value).map { String(value[$0]) } }
        var components = DateComponents(calendar:utcCalendar,timeZone:TimeZone(identifier:"UTC"))
        components.year = Int(group(1)!); components.month = Int(group(2)!); components.day = Int(group(3)!)
        components.hour = Int(group(4)!); components.minute = Int(group(5)!); components.second = Int(group(6)!)
        guard components.isValidDate, let base = components.date else { throw NameError.invalidStart }
        let fraction = group(7).map { String($0.dropFirst()).padding(toLength:6,withPad:"0",startingAt:0) } ?? "0"
        return base.addingTimeInterval(Double(Int(fraction)!) / 1_000_000)
    }
    private static let utcCalendar: Calendar = { var c = Calendar(identifier:.gregorian); c.timeZone = TimeZone(identifier:"UTC")!; return c }()
    /// The wall-clock minute (floored, 24 h) of `instant` in `zone`.
    static func format(_ instant: Date, zone: TimeZone?) throws -> String {
        guard let zone else { throw NameError.unknownZone }
        var calendar = Calendar(identifier:.gregorian); calendar.timeZone = zone
        let c = calendar.dateComponents([.year,.month,.day,.hour,.minute],from:instant)
        return String(format:"%04d-%02d-%02d--%02d.%02d-",c.year!,c.month!,c.day!,c.hour!,c.minute!)
    }
    static func zoned(_ utc: String, _ identifier: String) throws -> (String,Int) {
        guard let zone = TimeZone(identifier:identifier) else { throw NameError.unknownZone }
        let instant = try parseUTC(utc)
        return (try format(instant,zone:zone),Int((Double(zone.secondsFromGMT(for:instant)) / 60).rounded(.down)))
    }
    /// A complete DATE (seconds required) with `Z` or `±HH:MM` within -720..+840, never `-00:00`.
    static func dateTag(_ tag: String) -> (prefix: String, offset: Int)? {
        let pattern = #"^([0-9]{4})-([0-9]{2})-([0-9]{2})T([0-9]{2}):([0-9]{2}):([0-9]{2})(\.[0-9]+)?(Z|[+-][0-9]{2}:[0-9]{2})$"#
        guard let match = try? NSRegularExpression(pattern:pattern).firstMatch(in:tag,range:NSRange(tag.startIndex...,in:tag)) else { return nil }
        func group(_ i: Int) -> String { String(tag[Range(match.range(at:i),in:tag)!]) }
        let zone = group(8)
        guard zone != "-00:00" else { return nil }
        let offset = zone == "Z" ? 0 : (zone.hasPrefix("-") ? -1 : 1) * (Int(zone.dropFirst().prefix(2))! * 60 + Int(zone.suffix(2))!)
        guard validOffset(offset) else { return nil }
        let (y,mo,d,h,mi,s) = (Int(group(1))!,Int(group(2))!,Int(group(3))!,Int(group(4))!,Int(group(5))!,Int(group(6))!)
        let check = DateComponents(calendar:utcCalendar,timeZone:TimeZone(identifier:"UTC"),year:y,month:mo,day:d,hour:h,minute:mi,second:s)
        guard check.isValidDate else { return nil }
        return (String(format:"%04d-%02d-%02d--%02d.%02d-",y,mo,d,h,mi),offset)
    }

    // MARK: title

    private static func forbidden(_ v: UInt32) -> Bool {
        if v < 0x20 || v == 0x7F || "/\\:*?\"<>|".unicodeScalars.contains(where:{ $0.value == v }) { return true }
        if (0x80...0x9F).contains(v) && v != 0x85 { return true }
        return (0x202A...0x202E).contains(v) || (0x2066...0x2069).contains(v) || [0xFEFF,0xFFFE,0xFFFF].contains(v) || (0xD800...0xDFFF).contains(v)
    }
    private static func whiteSpace(_ v: UInt32) -> Bool {
        (0x09...0x0D).contains(v) || [0x20,0x85,0xA0,0x1680,0x2028,0x2029,0x202F,0x205F,0x3000].contains(v) || (0x2000...0x200A).contains(v)
    }
    /// The title sanitized for the name only: NFC, forbidden characters to "-", White_Space
    /// runs to one space, spaces and dots trimmed, stream-safe; empty becomes `untitled`.
    public static func sanitize(_ title: String, untitled: String) -> String {
        sanitize(scalars:Array(nfc(title).unicodeScalars),untitled:untitled)
    }
    static func sanitize(scalars input: [Unicode.Scalar], untitled: String) -> String {
        let dash = Unicode.Scalar(0x2D)!, space = Unicode.Scalar(0x20)!
        var out: [Unicode.Scalar] = [], pending = false
        for scalar in input.map({ forbidden($0.value) ? dash : $0 }) {
            if whiteSpace(scalar.value) { pending = true; continue }
            if pending && !out.isEmpty { out.append(space) }
            pending = false; out.append(scalar)
        }
        let trimmed = trim(out)
        var safe: [Unicode.Scalar] = [], run = 0
        for scalar in trimmed {
            run = scalar.properties.canonicalCombiningClass.rawValue != 0 ? run + 1 : 0
            if run <= maxNonStarters { safe.append(scalar) }
        }
        return safe.isEmpty ? untitled : string(safe)
    }
    /// A title given as UTF-16 code units (S-12 §11): valid pairs combine, each unpaired
    /// surrogate becomes "-", as the reference's sanitizer turns lone surrogates into "-".
    public static func title(utf16 units: [UInt16]) -> String {
        var out = String.UnicodeScalarView(), i = 0
        while i < units.count {
            let u = units[i]
            if (0xD800...0xDBFF).contains(u), i + 1 < units.count, (0xDC00...0xDFFF).contains(units[i+1]) {
                out.append(Unicode.Scalar(0x10000 + ((UInt32(u) - 0xD800) << 10) + (UInt32(units[i+1]) - 0xDC00))!); i += 2
            } else {
                out.append(Unicode.Scalar(UInt32(u)) ?? Unicode.Scalar(0x2D)!); i += 1
            }
        }
        return String(out)
    }
    private static func trim(_ s: [Unicode.Scalar]) -> [Unicode.Scalar] {
        let edge: (Unicode.Scalar) -> Bool = { $0.value == 0x20 || $0.value == 0x2E }
        guard let first = s.firstIndex(where:{ !edge($0) }), let last = s.lastIndex(where:{ !edge($0) }) else { return [] }
        return Array(s[first...last])
    }
    private static func string(_ s: [Unicode.Scalar]) -> String { var v = String.UnicodeScalarView(); v.append(contentsOf:s); return String(v) }
    private static func bytes(_ s: ArraySlice<Unicode.Scalar>) -> Int { s.reduce(0) { $0 + UTF8.width($1) } }

    // MARK: grapheme approximation G1-G5 and truncation

    private static func regionalIndicator(_ s: Unicode.Scalar) -> Bool { (0x1F1E6...0x1F1FF).contains(s.value) }
    private static func jamo(_ s: Unicode.Scalar) -> Character? {
        switch s.value {
        case 0x1100...0x115F, 0xA960...0xA97C: return "L"
        case 0x1160...0x11A7, 0xD7B0...0xD7C6: return "V"
        case 0x11A8...0x11FF, 0xD7CB...0xD7FB: return "T"
        case 0xAC00...0xD7A3: return "S"
        default: return nil
        }
    }
    /// Indices i (0 < i < count) where a cluster may end before s[i].
    static func boundaries(_ s: [Unicode.Scalar]) -> [Int] {
        var result: [Int] = [], run = 0
        for i in 1..<max(1,s.count) {
            let a = s[i-1], b = s[i]
            run = regionalIndicator(a) ? run + 1 : 0
            if [.nonspacingMark,.spacingMark,.enclosingMark].contains(b.properties.generalCategory) { continue }
            if b.value == 0x200D || a.value == 0x200D { continue }
            if (0x1F3FB...0x1F3FF).contains(b.value) || (0xE0020...0xE007F).contains(b.value) { continue }
            if regionalIndicator(a) && regionalIndicator(b) && run % 2 == 1 { continue }
            let ja = jamo(a), jb = jamo(b)
            if jb == "V" || jb == "T" || (ja == "L" && (jb == "L" || jb == "V" || jb == "S")) { continue }
            result.append(i)
        }
        return result
    }
    /// The longest prefix of whole clusters within `limit` UTF-8 bytes, trailing spaces and dots trimmed.
    static func truncate(_ s: [Unicode.Scalar], limit: Int) -> [Unicode.Scalar] {
        if bytes(s[...]) <= limit { return s }
        var cut = 0
        for i in boundaries(s) {
            if bytes(s[..<i]) > limit { break }
            cut = i
        }
        if cut == 0 { cut = (0...s.count).last { bytes(s[..<$0]) <= limit } ?? 0 }
        var out = Array(s[..<cut])
        while let last = out.last, last.value == 0x20 || last.value == 0x2E { out.removeLast() }
        return out
    }

    // MARK: whole name

    /// S-12 §11 Q5: the canonical caseless key NFC(casefold(NFD(name))).
    public static func fold(_ name: String) -> String {
        nfc(name.decomposedStringWithCanonicalMapping.folding(options:[.caseInsensitive],locale:nil))
    }
    /// NFC. Foundation composes an L jamo with an archaic V (U+1176...) or an LV syllable with
    /// an archaic T (U+11C3...) into a wrong syllable (U+1100 U+1176 U+11A8 becomes U+AE4D);
    /// Unicode never composes them. Those jamo are starters that compose with nothing, so the
    /// text is normalized in pieces split before each of them.
    public static func nfc(_ text: String) -> String {
        var pieces: [String] = [], current = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            let v = scalar.value
            if ((0x1176...0x11A7).contains(v) || (0x11C3...0x11FF).contains(v) || (0xD7B0...0xD7FB).contains(v)), !current.isEmpty {
                pieces.append(String(current)); current = .init()
            }
            current.append(scalar)
        }
        pieces.append(String(current))
        return pieces.map(\.precomposedStringWithCanonicalMapping).joined()
    }
    /// The smallest free suffix, ignoring the meeting's own current name. The publisher owns
    /// the EEXIST retry (add the rejected name to `existing` and call again).
    public static func fileName(prefix: String, title: String, untitled: String, existing: [String] = [], own: String? = nil) throws -> (name: String, sanitized: String) {
        guard isPrefix(prefix) else { throw NameError.invalidPrefix }
        let clean = sanitize(title,untitled:untitled), scalars = Array(clean.unicodeScalars)
        var taken = Set(existing.map(fold))
        if let own { taken.remove(fold(own)) }
        for n in 1... {
            let suffix = n == 1 ? "" : " (\(n))"
            let budget = maxBytes - prefixBytes - suffix.utf8.count - fileExtension.utf8.count
            let name = prefix + string(truncate(scalars,limit:budget)) + suffix + fileExtension
            if !taken.contains(fold(name)) { return (name,clean) }
        }
        fatalError("unreachable")
    }
}
