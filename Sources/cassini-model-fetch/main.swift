// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import CassiniModels
import Darwin

// Build/test utility; never bundled in Cassini.app. Uses the same pinned D4
// installer as the Download button, with no latest-model selection.
let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count == 2, arguments[0] == "--output" else {
    fputs("Usage: cassini-model-fetch --output APP_DATA_DIRECTORY\n",stderr); exit(64)
}
let pin = ModelPin(id:"parakeet-ultra-0.6b-int8",sourceSHA256:"18cb623004dd6c15999b93cb70b14d8a1f6e8f3a2a97ff733f104bfc3494f6a9")
do {
    let output = URL(fileURLWithPath:arguments[1],isDirectory:true)
    try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
    let downloader = ModelDownloader(appData:output)
    let installed = try await downloader.install(pin)
    print(installed.path)
} catch {
    fputs("Pinned model fetch failed: \(error)\n",stderr); exit(1)
}
