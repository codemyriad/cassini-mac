// SPDX-License-Identifier: GPL-3.0-or-later
#if DEBUG
import AppKit
import CassiniBrowserSetup

/// Hosted installed-app check only: the browser supplies the real management
/// connection. This entry point neither registers a fixture host nor captures.
@MainActor enum BrowserBackgroundSelfTest {
    static func run() async {
        guard ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] == "true",
              ProcessInfo.processInfo.environment["RUNNER_ENVIRONMENT"] == "github-hosted",
              ProcessInfo.processInfo.environment["CASSINI_HOSTED_SCREENSHOTS"] == "1",
              let path = ProcessInfo.processInfo.environment["CASSINI_CONTROL_PIPE_ROOT"], path.contains("/browser-background-") else { exit(77) }
        await CaptureCollection.shared.start(root:URL(fileURLWithPath:path,isDirectory:true))
        CompanionSetup.shared.start()
        let deadline = ProcessInfo.processInfo.systemUptime + 85
        do {
            while !CaptureCollection.shared.connected && ProcessInfo.processInfo.systemUptime < deadline {
                try await Task.sleep(for:.milliseconds(50))
            }
            guard CaptureCollection.shared.connected, CompanionSetup.shared.started else { throw BrowserSetupError.unavailable }
            let report: [String:Any] = ["connectedWithoutClick":true,"bundledSetupService":true,"capturedAudio":false,
                "uiActions":0,"state":CompanionSetup.shared.stateLine]
            try FileHandle.standardOutput.write(contentsOf:JSONSerialization.data(withJSONObject:report,options:[.sortedKeys]) + Data([10]))
            CompanionSetup.shared.stop(); await CaptureCollection.shared.shutdown(); exit(0)
        } catch {
            try? FileHandle.standardError.write(contentsOf:Data(("Background setup failed: \(CompanionSetup.shared.background.state) / \(error)\n").utf8)); exit(1)
        }
    }
}
#endif
