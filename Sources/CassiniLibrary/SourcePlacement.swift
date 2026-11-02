// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import CassiniKit

/// D52 M1 / R64: spans of one source become one speaker only when their exact
/// half-open physical extents are disjoint. Matches GNOME `d52-source-grouping`.
public enum SourceSpanLanes {
    public struct Span: Sendable {
        public let id: String, base: String
        public let startMs: Double?, endMs: Double?
        /// The span's length in samples, when known: its end is then exactly
        /// start + frames/rate, never a rounded floating-point sum.
        public let frames: UInt64?, sampleRate: Int?
        public init(id: String, base: String, startMs: Double?, endMs: Double?, frames: UInt64? = nil, sampleRate: Int? = nil) {
            self.id = id; self.base = base; self.startMs = startMs; self.endMs = endMs; self.frames = frames; self.sampleRate = sampleRate
        }
        /// Half-open extents are compared exactly: the decimal start as written (its shortest
        /// round-trip form) plus whole samples, so 16.036 ms + 48003 samples at 48 kHz ends at
        /// 1016.0985, adjacent to a span starting there.
        func ends(atOrBefore other: Double) -> Bool {
            guard let startMs, let endMs else { return false }
            let next = Self.decimal(other)
            if let frames, let sampleRate, sampleRate > 0 {
                return Decimal(frames) * 1000 <= (next - Self.decimal(startMs)) * Decimal(sampleRate)
            }
            return Self.decimal(endMs) <= next
        }
        static func decimal(_ value: Double) -> Decimal {
            Decimal(string:String(describing:value),locale:Locale(identifier:"en_US_POSIX")) ?? Decimal(value)
        }
    }
    /// Lane zero keeps the base id; further lanes are `base:overlap:n` (n from 1),
    /// skipping any id already used by an ordinary base. Unknown extents always
    /// take a new lane. Input order never affects the result.
    public static func assign(_ spans: [Span]) -> [String:String] {
        func bytes(_ value: String) -> [UInt8] { Array(value.utf8) }
        var taken = Set(spans.map(\.base)), result: [String:String] = [:]
        let groups = Dictionary(grouping:spans,by:\.base).sorted { bytes($0.key).lexicographicallyPrecedes(bytes($1.key)) }
        for (base,members) in groups {
            let known = members.filter { $0.startMs != nil && $0.endMs != nil }.sorted {
                ($0.startMs!,$0.endMs!) != ($1.startMs!,$1.endMs!) ? ($0.startMs!,$0.endMs!) < ($1.startMs!,$1.endMs!) : bytes($0.id).lexicographicallyPrecedes(bytes($1.id))
            }
            let unknown = members.filter { $0.startMs == nil || $0.endMs == nil }.sorted { bytes($0.id).lexicographicallyPrecedes(bytes($1.id)) }
            var lanes: [(end: Span?, id: String)] = [], next = 1
            func newLane() -> String {
                if lanes.isEmpty { return base }
                while taken.contains(base+":overlap:\(next)") { next += 1 }
                let id = base+":overlap:\(next)"; taken.insert(id); next += 1; return id
            }
            for span in known {
                if let lane = lanes.firstIndex(where:{ $0.end?.ends(atOrBefore:span.startMs!) == true }) {
                    lanes[lane].end = span; result[span.id] = lanes[lane].id
                } else {
                    let id = newLane(); lanes.append((span,id)); result[span.id] = id
                }
            }
            for span in unknown { let id = newLane(); lanes.append((nil,id)); result[span.id] = id }
        }
        return result
    }
}

/// D49/D33 half-open ownership of "the others": at every othersSource.atMs the
/// outgoing source stops owning audio. Applied to placement before recognition,
/// mixdown and export; never a transcript display rule. The microphone is never masked.
public struct OthersOwnership: Sendable, Equatable {
    private let changes: [(at: Double, owner: String)]
    public static func == (a: Self, b: Self) -> Bool { a.changes.elementsEqual(b.changes) { $0.at == $1.at && $0.owner == $1.owner } }
    /// nil when the capture recorded no source changes (nothing to mask).
    public init?(events: [CaptureEvent]) {
        let changes = events.compactMap { event -> (Double,String)? in
            guard event.type == "othersSource", let at = event.atMs, let source = event.source else { return nil }
            return (at,source)
        }
        guard !changes.isEmpty else { return nil }
        self.changes = changes
    }
    public static func role(kind: String?) -> String? {
        switch kind {
        case "microphone","local": return nil
        case "system": return "system"
        default: return "browser"
        }
    }
    /// Owned sub-intervals of [startMs, endMs) for a track of this kind.
    public func owned(kind: String?, startMs: Double, endMs: Double) -> [(Double,Double)] {
        guard endMs > startMs else { return [] }
        guard let role = Self.role(kind:kind) else { return [(startMs,endMs)] }
        var result: [(Double,Double)] = []
        // Before the first recorded change, nothing is known: keep the audio.
        if changes[0].at > startMs { result.append((startMs,min(endMs,changes[0].at))) }
        for (index,change) in changes.enumerated() where change.owner == role {
            let until = index + 1 < changes.count ? changes[index+1].at : .infinity
            let a = max(startMs,change.at), b = min(endMs,until)
            if b > a {
                if let last = result.last, last.1 == a { result[result.count-1].1 = b } else { result.append((a,b)) }
            }
        }
        return result
    }
}
