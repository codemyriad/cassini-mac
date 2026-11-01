// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import CassiniKit

/// D52 M1 / R64: spans of one source become one speaker only when their exact
/// half-open physical extents are disjoint. Matches GNOME `d52-source-grouping`.
public enum SourceSpanLanes {
    public struct Span: Sendable {
        public let id: String, base: String
        public let startMs: Double?, endMs: Double?
        public init(id: String, base: String, startMs: Double?, endMs: Double?) { self.id = id; self.base = base; self.startMs = startMs; self.endMs = endMs }
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
            var lanes: [(end: Double?, id: String)] = [], next = 1
            func newLane() -> String {
                if lanes.isEmpty { return base }
                while taken.contains(base+":overlap:\(next)") { next += 1 }
                let id = base+":overlap:\(next)"; taken.insert(id); next += 1; return id
            }
            for span in known {
                if let lane = lanes.firstIndex(where:{ $0.end.map { $0 <= span.startMs! } == true }) {
                    lanes[lane].end = span.endMs; result[span.id] = lanes[lane].id
                } else {
                    let id = newLane(); lanes.append((span.endMs,id)); result[span.id] = id
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
