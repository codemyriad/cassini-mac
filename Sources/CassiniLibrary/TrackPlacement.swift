// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// D55 (M9): one placement of a track on the session timeline for every consumer.
/// Recognition (16 kHz), the export mix (48 kHz) and playback (the track's own rate)
/// each place a track that starts at `startOffsetMs` at session frame
/// `startOffsetMs · rate / 1000`, rounded half away from zero, at their own rate.
/// An unknown offset is placed at 0 by recognition and export (and flagged), while
/// playback refuses it (D19).
public enum TrackPlacement {
    public static func frame(ms: Double, rate: Int) -> Int64 {
        Int64((ms * Double(rate) / 1000).rounded(.toNearestOrAwayFromZero))
    }
}
