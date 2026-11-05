// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// D58.2 R2: macOS feeds a denied system-audio tap digital silence instead of an error, so since
/// D58.1 a denial looks exactly like a quiet start. While recording, when some other app is
/// playing and the others' (system) input has delivered nothing but digital silence for 5 s, the
/// permission line is shown. It clears on the first non-zero audio. The cause is inferred, not
/// reported, so nothing is written to refusals.
public struct SilentOthersHint: Sendable {
    public static let after: TimeInterval = 5
    private var since: TimeInterval?
    private var heard = false
    public init() {}
    /// `silent`: the running system input has delivered only digital silence (nil: no such input).
    /// `playing`: another process is playing audio now. Returns whether the hint shows.
    public mutating func update(silent: Bool?, playing: Bool, now: TimeInterval) -> Bool {
        if silent == false { heard = true }
        guard !heard, silent == true, playing else { since = nil; return false }
        let start = since ?? now; since = start
        return now - start >= Self.after
    }
}
