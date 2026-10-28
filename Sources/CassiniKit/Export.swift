// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// `m:ss`, or `h:mm:ss` from an hour.
public func formatClock(_ ms: Int) -> String {
    let s = max(0, ms / 1000)
    let h = s / 3600, m = (s % 3600) / 60, ss = s % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, ss) : String(format: "%d:%02d", m, ss)
}
