// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import CassiniKit

/// D112 (L-87): Set date and time on a meeting.
/// Stores `startedAt` (RFC 3339 with explicit UTC offset, seconds floored) and
/// `startedAtSource: "user"` in meeting.json without ever renaming the Library folder.
public enum MeetingDateTime {
    public struct Prefill: Equatable, Sendable {
        public let date: Date
        public let fromFileSavedTime: Bool
        public init(date: Date, fromFileSavedTime: Bool) {
            self.date = date
            self.fromFileSavedTime = fromFileSavedTime
        }
    }

    /// Prefill rules (D-1165):
    /// 1. The recording time if there is one (`fromFileSavedTime == false`).
    /// 2. Otherwise the file's last-saved time minus the length (`fromFileSavedTime == true`).
    /// 3. Otherwise today at the current time (`fromFileSavedTime == false`).
    public static func prefill(for meeting: LibraryMeeting, now: Date = Date(), timeZone: TimeZone = .current) -> Prefill {
        if let time = meeting.meetingTime {
            if let instant = time.instant {
                return Prefill(date: instant, fromFileSavedTime: false)
            }
            if let components = time.localComponents {
                var calendar = Calendar(identifier: .gregorian)
                calendar.timeZone = timeZone
                var local = DateComponents()
                local.year = components.year
                local.month = components.month
                local.day = components.day
                local.hour = components.hour
                local.minute = components.minute
                local.second = components.second
                if let resolved = calendar.date(from: local) {
                    return Prefill(date: resolved, fromFileSavedTime: false)
                }
            }
        }
        if let file = meeting.audioFiles.first,
           let attrs = try? FileManager.default.attributesOfItem(atPath: file.path),
           let savedAt = attrs[.modificationDate] as? Date {
            let durationSeconds = Double(max(0, meeting.durationMs ?? 0)) / 1000.0
            let estimated = savedAt.addingTimeInterval(-durationSeconds)
            return Prefill(date: estimated, fromFileSavedTime: true)
        }
        return Prefill(date: now, fromFileSavedTime: false)
    }

    /// Combine a calendar day from `day` with hour/minute from `clock` in `timeZone` (seconds floored to 0).
    public static func combine(day: Date, clock: Date, timeZone: TimeZone = .current) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let d = calendar.dateComponents([.year, .month, .day], from: day)
        let t = calendar.dateComponents([.hour, .minute], from: clock)
        var combined = DateComponents()
        combined.year = d.year
        combined.month = d.month
        combined.day = d.day
        combined.hour = t.hour
        combined.minute = t.minute
        combined.second = 0
        return calendar.date(from: combined) ?? day
    }

    public static func apply(_ date: Date, timeZone: TimeZone = .current, to meeting: LibraryMeeting) throws {
        guard meeting.state.lifecycle == .saved, !meeting.metadataReadOnly else { throw POSIXError(.EPERM) }
        let formatted = MeetingTime.formatStartedAt(date, timeZone: timeZone)
        try MeetingMetadataWriter(directory: meeting.folder, id: meeting.id).transaction {
            $0["startedAt"] = formatted
            $0["startedAtSource"] = "user"
        }
    }
}
