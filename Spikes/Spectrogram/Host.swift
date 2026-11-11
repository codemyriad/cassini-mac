// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Darwin

/// Private diagnostic admission; never broadens normal app behavior.
enum SpectrogramFixtureHost {
    static func admits(_ environment:[String:String],uid:UInt32,consoleUID:UInt32,aqua:Bool)->Bool {
        guard environment["GITHUB_ACTIONS"] == "true" else { return false }
        if environment["RUNNER_ENVIRONMENT"] == "github-hosted" { return true }
        return environment["RUNNER_ENVIRONMENT"] == "self-hosted" &&
            environment["CASSINI_CI_GUI"] == "1" && uid == 503 && consoleUID == uid && aqua
    }
    static var current: Bool {
        let environment=ProcessInfo.processInfo.environment
        if environment["RUNNER_ENVIRONMENT"] == "github-hosted" {
            return admits(environment,uid:getuid(),consoleUID:0,aqua:false)
        }
        let uid=getuid()
        let attributes=try? FileManager.default.attributesOfItem(atPath:"/dev/console")
        guard let console=(attributes?[.ownerAccountID] as? NSNumber)?.uint32Value else { return false }
        let process=Process()
        process.executableURL=URL(fileURLWithPath:"/bin/launchctl")
        process.arguments=["print","gui/\(uid)"]
        process.standardOutput=FileHandle.nullDevice;process.standardError=FileHandle.nullDevice
        do { try process.run();process.waitUntilExit() } catch { return false }
        return admits(environment,uid:uid,consoleUID:console,aqua:process.terminationStatus == 0)
    }
}
