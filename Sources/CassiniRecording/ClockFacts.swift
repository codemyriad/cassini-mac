// SPDX-License-Identifier: GPL-3.0-or-later
import CassiniKit

/// D61 (protocol #39): the three record-only clock facts a browser `track` declares.
/// Hosts copy each one into the session.json track as received, and omit it when it is
/// absent or invalid. No reader moves or widens a track with them.
public struct ClockFacts: Sendable, Equatable {
    public static let methods: Set<String> = ["outputTimestamp","roundTrip"]
    public static let maximumMs = 86_400_000
    public var method: String?, uncertaintyMs: Int?, clampMs: Int?
    public init(method: String? = nil, uncertaintyMs: Int? = nil, clampMs: Int? = nil) {
        self.method = method.flatMap { Self.methods.contains($0) ? $0 : nil }
        self.uncertaintyMs = uncertaintyMs.flatMap { (0...Self.maximumMs).contains($0) ? $0 : nil }
        self.clampMs = clampMs.flatMap { (1...Self.maximumMs).contains($0) ? $0 : nil }
    }
    /// Each fact on its own: an integer literal in range (never a fraction or exponent),
    /// or one of the two methods. nil when none is valid.
    public static func parse(_ json: JSON) -> ClockFacts? {
        func integer(_ key: String) -> Int? {
            guard case .number(let literal)? = json[key], literal.allSatisfy({ $0.isNumber || $0 == "-" }) else { return nil }
            return Int(literal)
        }
        let facts = ClockFacts(method:json["clockMethod"]?.string,uncertaintyMs:integer("clockUncertaintyMs"),clampMs:integer("clockClampMs"))
        return facts.isEmpty ? nil : facts
    }
    public var isEmpty: Bool { method == nil && uncertaintyMs == nil && clampMs == nil }
}
