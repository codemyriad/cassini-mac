// SPDX-License-Identifier: GPL-3.0-or-later
import Testing
@testable import CassiniSpectrogram

@Suite struct SelectionTests {
    @Test func fourVoicesUseOnlyTheLoudestThreeAndRechooseOncePerSecond() {
        var selection = SpectrogramSelection()
        #expect(selection.choose(levels:[0:0.1,1:0.4,2:0.3,3:0.2],nowMs:0) == [1,2,3])
        #expect(selection.choose(levels:[0:0.9,1:0.4,2:0.3,3:0.2],nowMs:999) == [1,2,3])
        #expect(selection.choose(levels:[0:0.9,1:0.4,2:0.3,3:0.2],nowMs:1000) == [0,1,2])
        // A closed view drops its histories/selection; reopening starts fresh.
        selection.reset()
        #expect(selection.choose(levels:[0:0,3:0,2:.nan,1:0],nowMs:1001) == [0,1,2])
    }
    @Test func concurrentSessionsNeverShareTheirTrackSelection() {
        var first = SpectrogramSelection(), second = SpectrogramSelection()
        #expect(first.choose(levels:[0:0.2,1:0.1],nowMs:0) == [0,1])
        #expect(second.choose(levels:[4:0.8,5:0.5],nowMs:0) == [4,5])
        #expect(first.tracks == [0,1])
    }
}
