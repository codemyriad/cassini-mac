// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import Combine

/// Weak ownership avoids keeping a closed Library window alive through its view.
@MainActor final class ImportedNoticeWindow {
    weak var window: NSWindow?

    static var events: Publishers.MergeMany<NotificationCenter.Publisher> {
        Publishers.MergeMany([
            NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
            NSWindow.willBeginSheetNotification, NSWindow.didEndSheetNotification,
            NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification,
        ].map { NotificationCenter.default.publisher(for: $0) })
    }
}
