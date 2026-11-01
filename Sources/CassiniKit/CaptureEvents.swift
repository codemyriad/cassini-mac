// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

public enum CaptureEndReason: String, Codable, CaseIterable, Sendable {
    case user, callEnded, tabClosed, pageGone, disk, error, appQuit
}

/// Optional session v1 provenance. Unknown or malformed events do not invalidate
/// playable audio; readers ignore them and never infer an event from a gap.
public struct CaptureEvent: Codable, Sendable, Equatable {
    public let atMs: Double?
    public let type: String
    public let source: String?
    public let reason: String?
    public let me: Bool?
    public let others: Bool?
    public init(atMs: Double, type: String, source: String? = nil, reason: String, me: Bool? = nil, others: Bool? = nil) {
        self.atMs = atMs; self.type = type; self.source = source; self.reason = reason; self.me = me; self.others = others
    }
    public var isKnownValid: Bool {
        guard let atMs, atMs.isFinite, atMs >= 0 else { return false }
        switch type {
        case "othersSource":
            if reason == "restored" || reason == "callConnected" { return source == "browser" }
            return ["browser","system","none"].contains(source ?? "") && ["start","missing","lost","user"].contains(reason ?? "")
        case "selection": return me != nil && others != nil && (me == true || others == true) && ["start","user"].contains(reason ?? "")
        case "end": return reason.flatMap(CaptureEndReason.init(rawValue:)) != nil
        default: return false
        }
    }
    enum CodingKeys: String, CodingKey { case atMs, type, source, reason, me, others }
    public init(from decoder: Decoder) throws {
        guard let c = try? decoder.container(keyedBy:CodingKeys.self) else {
            atMs = nil; type = ""; source = nil; reason = nil; me = nil; others = nil; return
        }
        atMs = try? c.decode(Double.self,forKey:.atMs)
        type = (try? c.decode(String.self,forKey:.type)) ?? ""
        reason = try? c.decode(String.self,forKey:.reason)
        source = type == "othersSource" ? try? c.decode(String.self,forKey:.source) : nil
        me = type == "selection" ? try? c.decode(Bool.self,forKey:.me) : nil
        others = type == "selection" ? try? c.decode(Bool.self,forKey:.others) : nil
    }
    public func encode(to encoder: Encoder) throws {
        guard isKnownValid else { throw EncodingError.invalidValue(self,.init(codingPath:encoder.codingPath,debugDescription:"Only valid known capture events may be written.")) }
        var c = encoder.container(keyedBy:CodingKeys.self)
        try c.encode(atMs,forKey:.atMs); try c.encode(type,forKey:.type); try c.encode(reason,forKey:.reason)
        if type == "othersSource" { try c.encode(source,forKey:.source) }
        else if type == "selection" { try c.encode(me,forKey:.me); try c.encode(others,forKey:.others) }
    }
    /// Preserve valid ordered provenance only. A bad entry never rewinds a later
    /// event or manufactures a fallback. Unknown fields are intentionally unused.
    public static func read(_ raw: JSON?) -> [CaptureEvent] {
        guard let array = raw?.array, array.count <= 1000 else { return [] }
        var result: [CaptureEvent] = [], previous: Double = 0
        for value in array {
            guard let time = value["atMs"]?.double, let type = value["type"]?.string else { continue }
            let event = CaptureEvent(atMs:time,type:type,source:value["source"]?.string,reason:value["reason"]?.string ?? "",me:value["me"]?.bool,others:value["others"]?.bool)
            guard event.isKnownValid, time >= previous else { continue }
            if event.type == "othersSource", event.reason == "restored" || event.reason == "callConnected" {
                guard CaptureSourceState(events:result,atMs:time).admitsBrowserReturn(event.reason) else { continue }
            }
            result.append(event); previous = time
            if event.type == "end" { break }
        }
        return result
    }
}
public struct CaptureSourceState: Sendable, Equatable {
    public var me: Bool?
    public var others: Bool?
    public var source: String?
    public var reason: String?
    public var sinceMs: Double?
    public var fallback: Bool { reason == "missing" || reason == "lost" }
    /// `restored` returns from either fallback; D49 `callConnected` only takes over
    /// the initial system/missing stand-in. Both need an enabled others side.
    public func admitsBrowserReturn(_ reason: String?) -> Bool {
        guard others == true, source == "system" else { return false }
        switch reason {
        case "restored": return fallback
        case "callConnected": return self.reason == "missing"
        default: return false
        }
    }
    public init(events: [CaptureEvent], atMs: Double) {
        var previous: Double = 0
        for event in events {
            guard event.isKnownValid, let time = event.atMs, time >= previous else { continue }
            previous = time
            if event.type == "end" { break }
            guard time <= atMs else { continue }
            if event.type == "selection" { me = event.me; others = event.others }
            else if event.type == "othersSource" {
                if event.reason == "restored" || event.reason == "callConnected", !admitsBrowserReturn(event.reason) { continue }
                source = event.source; reason = event.reason; sinceMs = time
            }
        }
    }
}
