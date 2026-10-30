// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Explicit clocks/zones keep fixtures deterministic; wall times follow the user's locale.
public struct LibraryFormat: Sendable {
    public let timeZone: TimeZone
    public let now: Date
    public let locale: Locale
    public init(timeZone: TimeZone = .current, now: Date = Date(), locale: Locale = .current) { self.timeZone = timeZone; self.now = now; self.locale = locale }
    private var calendar: Calendar { var c = Calendar(identifier: .gregorian); c.locale = Locale(identifier: "en_GB"); c.timeZone = timeZone; return c }
    private func date(_ value: Date, pattern: String) -> String {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_GB")
        formatter.calendar = calendar; formatter.timeZone = timeZone; formatter.dateFormat = pattern
        return formatter.string(from: value)
    }
    private static func two(_ value: Int64) -> String { value < 10 ? "0" + String(value) : String(value) }
    public static func position(_ ms: Int64) -> String {
        let s = max(0, ms) / 1000
        return two(s / 3600) + ":" + two((s / 60) % 60) + ":" + two(s % 60)
    }
    public static func liveBadge(_ ms: Int64) -> String {
        let s = max(0, ms) / 1000
        return s < 3600 ? String(s / 60) + ":" + two(s % 60)
            : String(s / 3600) + ":" + two((s / 60) % 60) + ":" + two(s % 60)
    }
    public static func liveBig(_ ms: Int64) -> String { position(ms) }
    public static func meetingDuration(_ ms: Int64) -> String {
        let m = max(0, ms) / 60000
        if m == 0 { return "under 1 min" }
        if m < 60 { return "\(m) min" }
        return "\(m / 60) h " + two(m % 60) + " min"
    }
    public static func talkTime(_ ms: Int64) -> String {
        let s = max(0, ms) / 1000
        if s < 60 { return "\(s) s" }
        if s < 3600 { return "\(s / 60) min \(s % 60) s" }
        return "\(s / 3600) h " + two((s / 60) % 60) + " min"
    }
    public static func confirmedSpeech(_ ms: Int64) -> String { meetingDuration(ms) + " confirmed speech" }
    public func dayGroup(_ at: Date) -> String {
        if calendar.isDate(at, inSameDayAs: now) { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(at, inSameDayAs: yesterday) { return "Yesterday" }
        return date(at, pattern: calendar.component(.year, from: at) == calendar.component(.year, from: now) ? "EEEE d MMMM" : "EEEE d MMMM yyyy")
    }
    public func rowTime(_ at: Date) -> String {
        let formatter = DateFormatter(); formatter.locale = locale
        formatter.timeZone = timeZone; formatter.dateStyle = .none; formatter.timeStyle = .short
        return formatter.string(from:at)
    }
    public func previewSubtitle(_ at: Date, durationMs: Int64?, received: Bool = false) -> String {
        dayGroup(at) + ", " + rowTime(at) + (durationMs.map { " · " + Self.meetingDuration($0) } ?? "") + (received ? " · Received" : "")
    }
    public func searchDate(_ at: Date) -> String {
        let group = dayGroup(at)
        if group == "Today" || group == "Yesterday" { return group }
        return date(at, pattern: calendar.component(.year, from: at) == calendar.component(.year, from: now) ? "d MMMM" : "d MMMM yyyy")
    }
    public func searchContext(_ at: Date, durationMs: Int64?, positionMs: Int64) -> String {
        previewSubtitle(at, durationMs: durationMs) + " · at " + Self.position(positionMs)
    }
    public static func rowMeta(durationMs: Int64?, names: [String]) -> String {
        let namesText = names.prefix(3).joined(separator: ", ") + (names.count > 3 ? " +\(names.count - 3)" : "")
        return [durationMs.map(meetingDuration), namesText.isEmpty ? nil : namesText].compactMap { $0 }.joined(separator: " · ")
    }
    public static func eta(_ minutes: Int64) -> String {
        if minutes <= 0 { return "Transcribing, less than a minute left" }
        return "Transcribing, about \(minutes) \(minutes == 1 ? "minute" : "minutes") left"
    }
    public static func searchCount(places: Int64, meetings: Int64) -> String {
        "\(places) \(places == 1 ? "place" : "places") in \(meetings) \(meetings == 1 ? "meeting" : "meetings")"
    }
    public static func size(bytes: Int64, approximate: Bool = false) -> String {
        let bytes = max(0, bytes)
        // Integer quotient/remainder implements decimal half-up exactly, including
        // 1.25 GiB and large inputs, without overflowing bytes*10.
        let unit: Int64 = 1_048_576
        let mb = bytes / unit + (bytes % unit >= unit / 2 ? 1 : 0)
        let value: String
        if bytes < unit { value = "\(bytes / 1024 + (bytes % 1024 >= 512 ? 1 : 0)) KB" }
        else if mb < 1000 { value = "\(mb) MB" }
        else {
            let gb: Int64 = 1_073_741_824
            let fractional = (bytes % gb) * 10
            let tenths = (bytes / gb) * 10 + fractional / gb + (fractional % gb >= gb / 2 ? 1 : 0)
            value = "\(tenths / 10).\(tenths % 10) GB"
        }
        return (approximate ? "about " : "") + value
    }
}
