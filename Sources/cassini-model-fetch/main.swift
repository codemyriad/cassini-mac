// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import CassiniModels
import Darwin

// Build/test utility; never bundled in Cassini.app. Uses the same pinned D4
// installer as the Download button, with no latest-model selection.
var arguments = Array(CommandLine.arguments.dropFirst())
let voices = arguments.last == "--voices"
if voices { arguments.removeLast() }
guard arguments.count == 2, arguments[0] == "--output" else {
    fputs("Usage: cassini-model-fetch --output APP_DATA_DIRECTORY [--voices]\n",stderr); exit(64)
}
let pin: ModelPin = voices ? .savedVoices : .parakeetUltra
do {
    let output = URL(fileURLWithPath:arguments[1],isDirectory:true)
    try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
    // D54 covers shipped apps; this build tool names itself.
    let downloader = ModelDownloader(appData:output,userAgent:"cassini-model-fetch/1 (build tool)")
    let installed = try await downloader.install(pin)
    print(installed.path)
} catch {
    fputs("Pinned model fetch failed: \(error)\n",stderr); exit(1)
}
