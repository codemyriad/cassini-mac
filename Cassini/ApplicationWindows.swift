// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

/// Scene actions are usable before any Library view mounts. Commands refresh
/// them from their real environment even when every content window is closed.
@MainActor enum ApplicationWindows {
    private static var window=EnvironmentValues().openWindow
    private static var settings=EnvironmentValues().openSettings

    static func install(window:OpenWindowAction,settings:OpenSettingsAction) {
        self.window=window;self.settings=settings
    }
    static func library() { window(id:"library") }
    static func preferences() { settings() }
    static func legacy(_ url:URL) { window(id:"legacy-viewer",value:LegacyRoute(url:url)) }
}
