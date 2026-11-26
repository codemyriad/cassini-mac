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

    public typealias FileModificationDateReader = @Sendable (URL) -> Date?

    public static func defaultFileModificationDate(at url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    /// Pure in-memory prefill from the meeting's already-known recording time (zero filesystem I/O).
    public static func knownPrefill(for meeting: LibraryMeeting, timeZone: TimeZone = .current) -> Prefill? {
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
        return nil
    }

    /// Prefill rules (D-1165):
    /// 1. The recording time if there is one (`fromFileSavedTime == false`).
    /// 2. Otherwise the file's last-saved time minus the length (`fromFileSavedTime == true`).
    /// 3. Otherwise today at the current time (`fromFileSavedTime == false`).
    public static func prefill(
        for meeting: LibraryMeeting,
        now: Date = Date(),
        timeZone: TimeZone = .current,
        fileModificationDate: FileModificationDateReader = defaultFileModificationDate
    ) -> Prefill {
        if let known = knownPrefill(for: meeting, timeZone: timeZone) {
            return known
        }
        if let file = meeting.audioFiles.first,
           let savedAt = fileModificationDate(file) {
            let durationSeconds = Double(max(0, meeting.durationMs ?? 0)) / 1000.0
            let estimated = savedAt.addingTimeInterval(-durationSeconds)
            return Prefill(date: estimated, fromFileSavedTime: true)
        }
        return Prefill(date: now, fromFileSavedTime: false)
    }

    /// Loads `MeetingDateTime.prefill` without blocking the main actor on filesystem I/O,
    /// protecting published state against cancellation and superseded/stale requests.
    @MainActor
    public final class PrefillLoader {
        private var generation: UInt64 = 0
        private var task: Task<Void, Never>?
        private let readModificationDate: FileModificationDateReader

        public init(readModificationDate: @escaping FileModificationDateReader = MeetingDateTime.defaultFileModificationDate) {
            self.readModificationDate = readModificationDate
        }

        public func cancel() {
            generation &+= 1
            task?.cancel()
            task = nil
        }

        @discardableResult
        public func load(
            for meeting: LibraryMeeting,
            now: Date = Date(),
            timeZone: TimeZone = .current,
            publish: @escaping @MainActor (Prefill, Bool) -> Void
        ) -> Task<Void, Never>? {
            cancel()
            if let known = MeetingDateTime.knownPrefill(for: meeting, timeZone: timeZone) {
                publish(known, false)
                return nil
            }
            guard !meeting.audioFiles.isEmpty else {
                publish(Prefill(date: now, fromFileSavedTime: false), false)
                return nil
            }
            publish(Prefill(date: now, fromFileSavedTime: false), true)
            let token = generation
            let reader = readModificationDate
            let fetchTask = Task<Void, Never> { [weak self] in
                let prefill = await Task.detached(priority: .userInitiated) {
                    MeetingDateTime.prefill(for: meeting, now: now, timeZone: timeZone, fileModificationDate: reader)
                }.value
                guard let self, !Task.isCancelled, self.generation == token else { return }
                self.task = nil
                publish(prefill, false)
            }
            task = fetchTask
            return fetchTask
        }
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
