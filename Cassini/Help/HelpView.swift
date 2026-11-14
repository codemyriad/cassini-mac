// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import CassiniLibrary
import SwiftUI

/// Offline in-app Help window (`HARMONY` §12, `D100`, `D-1033`): four concise topics,
/// zero external links, zero network calls.
struct HelpView: View {
    @State private var shortcut = RecordingRuntime.shared.shortcut

    private struct Topic: Identifiable {
        let id: String
        let icon: String
        let title: String
        let body: String
    }

    private var topics: [Topic] {
        [
            Topic(
                id: "help-topic-record",
                icon: "record.circle",
                title: UXText.text("help.record.title"),
                body: UXText.text("help.record.body", ["shortcut": shortcut.choice.glyph])
            ),
            Topic(
                id: "help-topic-library",
                icon: "folder",
                title: UXText.text("help.library.title"),
                body: UXText.text("help.library.body")
            ),
            Topic(
                id: "help-topic-trash",
                icon: "arrow.uturn.backward.circle",
                title: UXText.text("help.trash.title"),
                body: UXText.text("help.trash.body")
            ),
            Topic(
                id: "help-topic-voices",
                icon: "person.wave.2",
                title: UXText.text("help.voices.title"),
                body: UXText.text("help.voices.body")
            ),
        ]
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(topics) { topic in
                    HStack(alignment: .top, spacing: 14) {
                        Image(systemName: topic.icon)
                            .font(.system(size: 18, weight: .medium))
                            .foregroundStyle(CassiniTheme.accentInk)
                            .frame(width: 24, alignment: .center)
                            .padding(.top, 2)
                            .accessibilityHidden(true)

                        VStack(alignment: .leading, spacing: 6) {
                            Text(topic.title)
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(CassiniTheme.ink)
                            Text(topic.body)
                                .font(.system(size: 13))
                                .foregroundStyle(CassiniTheme.ink2)
                                .lineSpacing(4)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(18)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(CassiniTheme.surface, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(CassiniTheme.cardStroke))
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier(topic.id)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 480, minHeight: 400)
        .background(CassiniTheme.windowGround)
        .preferredColorScheme(
            LibraryLaunchContext.screenshotDark
                ? .dark
                : (LibraryLaunchContext.current.screenshot ? .light : nil)
        )
        .background(WindowAccessor { window in
            guard let window else { return }
            window.title = UXText.text("help.title")
            window.setAccessibilityIdentifier("cassini-help-window")
            RecordingConfirmation.attach(to: window)
        })
    }
}
