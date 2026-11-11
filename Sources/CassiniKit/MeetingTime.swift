// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// D95: an actual recording instant or an unzoned label, never an artifact stamp.
public struct MeetingTime: Sendable, Equatable {
    public enum Source: String, Sendable { case recordedAtUtc, date = "DATE", recordedAtLocal }
    public let source: Source
    public let value: String
    public let instant: Date?
    public let orderingKey: String
    public init(instant: Date) { self.init(source:.recordedAtUtc,value:Self.utcString(instant),instant:instant) }
    private init(source: Source, value: String, instant: Date? = nil) {
        self.source = source; self.value = value; self.instant = instant
        orderingKey = instant.map { String(Self.utcString($0).dropLast()) } ?? (value.count == 19 ? value + ".000" : value)
    }

    public static func resolve(meeting: Meeting?, dateTag: String?) -> Self? {
        if let value = meeting?.recordedAtUtc, let utc = normalizedUTC(value), let instant = parseInstant(utc) {
            return .init(source:.recordedAtUtc,value:utc,instant:instant)
        }
        if let dateTag, let date = parseInstant(dateTag), date != meeting.flatMap({ parseInstant($0.createdAtUtc) }) {
            return .init(source:.date,value:dateTag,instant:date)
        }
        if let label = meeting?.recordedAtLocal, !label.isEmpty { return .init(source:.recordedAtLocal,value:label) }
        return nil
    }
    public static func utcString(_ date: Date) -> String {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime,.withFractionalSeconds]
        f.timeZone = TimeZone(secondsFromGMT:0); return f.string(from:date)
    }
    /// RFC 3339 permits lowercase t/z. Keep precision and offset, normalizing
    /// only those ASCII letters before every Foundation parse or UTC validation.
    public static func normalizedRFC3339(_ value:String) -> String? {
        guard !value.hasSuffix("-00:00"), value == value.trimmingCharacters(in:.whitespacesAndNewlines),
              value.range(of:#"^[0-9]{4}-[0-9]{2}-[0-9]{2}[Tt][0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?([Zz]|[+-][0-9]{2}:[0-9]{2})$"#,options:.regularExpression) != nil else {return nil}
        return value.uppercased()
    }
    public static func normalizedUTC(_ value:String) -> String? {
        guard let normalized=normalizedRFC3339(value),normalized.hasSuffix("Z"),parseInstant(normalized) != nil else {return nil}
        return normalized
    }
    public static func parseInstant(_ value: String) -> Date? {
        guard let normalized=normalizedRFC3339(value) else {return nil}
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime,.withFractionalSeconds]
        if let date = f.date(from:normalized) { return date }
        f.formatOptions = [.withInternetDateTime]; return f.date(from:normalized)
    }
    /// Components retain the label's digits; this does not assign a recording zone.
    public var localComponents: DateComponents? {
        guard source == .recordedAtLocal, value.utf8.count == 19,
              value.range(of:#"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}$"#,options:.regularExpression) != nil else { return nil }
        let n = value.split(whereSeparator:{ "-T:".contains($0) }).compactMap { Int($0) }
        guard n.count == 6 else { return nil }
        var civil = Calendar(identifier:.gregorian); civil.timeZone = TimeZone(secondsFromGMT:0)!
        let c = DateComponents(calendar:civil,year:n[0],month:n[1],day:n[2],hour:n[3],minute:n[4],second:n[5])
        return c.isValidDate ? c : nil
    }
    /// A known legacy DATE survives; an uninformative DATE falls back to the artifact stamp.
    public static func dateTag(recordedAtUtc: String?, createdAtUtc: String, legacy: String?) -> String {
        if let recordedAtUtc { return recordedAtUtc }
        if let legacy, let instant = parseInstant(legacy), instant != parseInstant(createdAtUtc) { return legacy }
        return createdAtUtc
    }
}

extension CassiniFile {
    public var meetingTime: MeetingTime? {
        // An unreadable Cassini manifest cannot authenticate any fallback tag.
        guard state != .invalidCassiniMetadata, state != .unknownCassiniFormat else { return nil }
        return MeetingTime.resolve(meeting:manifest?.meeting,dateTag:tags?["DATE"])
    }
}
