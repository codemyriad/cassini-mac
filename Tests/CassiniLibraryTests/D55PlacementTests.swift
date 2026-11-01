// SPDX-License-Identifier: GPL-3.0-or-later
import Testing
@testable import CassiniLibrary

/// D55 (M9): one placement, offset · rate / 1000 rounded half away from zero.
struct D55PlacementTests {
    @Test func roundsHalfAwayFromZeroAtEachRate() {
        #expect(TrackPlacement.frame(ms:0,rate:16000) == 0)
        #expect(TrackPlacement.frame(ms:0.15625,rate:16000) == 3, "2.5 frames: half away from zero, not to even")
        #expect(TrackPlacement.frame(ms:0.09375,rate:16000) == 2, "1.5 frames")
        #expect(TrackPlacement.frame(ms:1234.5104,rate:16000) == 19752)
        #expect(TrackPlacement.frame(ms:1234.5104,rate:48000) == 59256)
        #expect(TrackPlacement.frame(ms:112.5,rate:44100) == 4961, "4961.25")
        #expect(TrackPlacement.frame(ms:86_400_000,rate:48000) == 4_147_200_000)
    }
}
