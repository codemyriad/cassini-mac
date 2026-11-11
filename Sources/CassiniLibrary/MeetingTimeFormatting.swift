// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import CassiniKit

extension LibraryFormat {
    /// Civil dates below are formatter scaffolding, never recording instants.
    /// The label's components stay unchanged, including at DST gaps/repetitions.
    private func meetingLabel(_ time: MeetingTime, _ render: (LibraryFormat,Date) -> String) -> String {
        if let instant = time.instant { return render(self,instant) }
        guard let components = time.localComponents, let civilDate = components.date else { return time.value }
        var viewer = Calendar(identifier:.gregorian); viewer.timeZone = timeZone
        var civil = Calendar(identifier:.gregorian); civil.timeZone = TimeZone(secondsFromGMT:0)!
        let today = civil.date(from:viewer.dateComponents([.year,.month,.day,.hour,.minute,.second],from:now))!
        return render(.init(timeZone:civil.timeZone,now:today,locale:locale,language:language),civilDate)
    }
    public func dayGroup(_ time: MeetingTime) -> String { meetingLabel(time) { $0.dayGroup($1) } }
    public func rowTime(_ time: MeetingTime) -> String { meetingLabel(time) { $0.rowTime($1) } }
    public func absoluteDate(_ time: MeetingTime) -> String { meetingLabel(time) { $0.absoluteDate($1) } }
    public func absoluteDateLine(_ time: MeetingTime, durationMs: Int64?) -> String { meetingLabel(time) { $0.absoluteDateLine($1,durationMs:durationMs) } }
    public func previewSubtitle(_ time: MeetingTime, durationMs: Int64?, received: Bool = false) -> String { meetingLabel(time) { $0.previewSubtitle($1,durationMs:durationMs,received:received) } }
    public func searchDate(_ time: MeetingTime) -> String { meetingLabel(time) { $0.searchDate($1) } }
    public func searchContext(_ time: MeetingTime, durationMs: Int64?, positionMs: Int64) -> String { meetingLabel(time) { $0.searchContext($1,durationMs:durationMs,positionMs:positionMs) } }
}
