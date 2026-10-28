// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
let listener = NSXPCListener.service()
let delegate = ModelDownloadListener()
listener.delegate = delegate
listener.resume()
