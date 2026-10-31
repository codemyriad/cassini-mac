// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit

/// Standalone harness only, never bundled with Cassini. Both this entry and the
/// probe require a disposable hosted runner before touching AppKit/any window.
@main struct SpectrogramProbe {
    @MainActor static func main() {
        let e = ProcessInfo.processInfo.environment
        guard e["GITHUB_ACTIONS"] == "true", e["RUNNER_ENVIRONMENT"] == "github-hosted" else { exit(78) }
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
