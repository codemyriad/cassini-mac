// SPDX-License-Identifier: GPL-3.0-or-later
// Filesystem-only Finder bookmark; never opens Finder or another application.
import Foundation

let target = URL(fileURLWithPath: CommandLine.arguments[1])
let data = try target.bookmarkData(options: .suitableForBookmarkFile,
                                 includingResourceValuesForKeys: nil, relativeTo: nil)
FileHandle.standardOutput.write(data)
