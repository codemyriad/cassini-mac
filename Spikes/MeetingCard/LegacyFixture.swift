// SPDX-License-Identifier: GPL-3.0-or-later
// Fixture adapters only. Actual row, badge, theme and background source is
// extracted verbatim by the producer; this is not a Library integration test.
import AppKit
import SwiftUI

struct MeetingBadge { let text: String; let tint: String; let dot: Bool? }
struct LibraryMeeting {
    let title: String?
    let meta: String
    let quote: String
    let libraryKey = "fixture"
    let meetingTime: Date? = Date(timeIntervalSince1970: 0)
    struct State { let badge: MeetingBadge? = nil }
    let state = State()
}
enum UXText { static func text(_ key: String) -> String { key } }
private struct FixtureFormat { func rowTime(_ date: Date) -> String { "09:00" } }
private struct FixtureStore {
    let selectedKeys: Set<String>
    let format = FixtureFormat()
}
struct LegacyCard: View {
    let selected: Bool
    let meeting: LibraryMeeting
    private var store: FixtureStore { FixtureStore(selectedKeys: selected ? ["fixture"] : []) }
    var body: some View {
        row(meeting).font(.system(size: 13))
            .padding(.vertical, 8).padding(.horizontal, 10)
            .background { background }
    }
    private func rowMeta(_ meeting: LibraryMeeting) -> String? { meeting.meta }
    private func rowSecondLine(_ meeting: LibraryMeeting) -> Text? { Text("“" + meeting.quote + "”") }
}
