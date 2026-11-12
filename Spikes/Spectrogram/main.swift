// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit

/// Standalone harness only, never bundled with Cassini. Both this entry and the
/// probe require qualified GUI CI before touching AppKit/any window.
@main struct SpectrogramProbe {
    @MainActor static func main() {
        guard SpectrogramFixtureHost.current else { exit(78) }
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let delegate = ProbeDelegate(); app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
private final class ProbeDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in await SpectrogramSelfTest.run() }
    }
}
