// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Metal
// Run only on the disposable hosted Mac, never on a user desktop.
guard ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] == "true",
      ProcessInfo.processInfo.environment["RUNNER_ENVIRONMENT"] == "github-hosted" else { exit(78) }
let devices = MTLCopyAllDevices().map { device -> [String: Any] in
    ["name": device.name, "isLowPower": device.isLowPower,
     "isRemovable": device.isRemovable, "hasUnifiedMemory": device.hasUnifiedMemory,
     "supportsApple7": device.supportsFamily(.apple7),
     "supportsMac2": device.supportsFamily(.mac2)]
}
let report: [String: Any] = ["devices": devices, "hasDefaultDevice": MTLCreateSystemDefaultDevice() != nil]
FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]))
