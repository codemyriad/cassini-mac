// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

@main struct CheckSampleClock {
    static func require(_ value: Bool, _ message: String) { if !value { FileHandle.standardError.write(Data((message+"\n").utf8)); exit(1) } }
    static func main() {
        for chunk in [4096,8192] {
            let clock = SpectrogramFixtureClock(chunk:chunk)
            let period = Double(chunk)/48000
            // Reproduce fractional-nanosecond repeat drift with an injected
            // clock. There is no wall-clock pause or scheduled test completion.
            let repeatedNanoseconds = Int(period*1e9)
            var sawEarlyWake = false
            for n in 1...2000 {
                let wake = Double(n*repeatedNanoseconds)/1e9+50e-9
                let ready = clock.completeFrames(at:wake)
                require(Double(ready)/48000 <= wake,"Never deliver future samples")
                if ready < n*chunk {
                    sawEarlyWake = true
                    let retry = clock.nextDelay(after:ready,elapsed:wake)
                    require(retry <= Double(n)*1e-9+1e-9,"Retry within the accumulated sub-nanosecond rounding error")
                    require(clock.completeFrames(at:wake+retry+1e-6) >= n*chunk,"The same packet becomes ready")
                }
            }
            require(sawEarlyWake,"Exercise both real fixture buffer sizes' repeat drift")
            let late = period*12.5
            let ready = clock.completeFrames(at:late)
            require(ready == chunk*12,"Late callbacks catch up on the sample clock")
            require(abs(clock.nextDelay(after:ready,elapsed:late)-period/2) < 1e-9,"Rearm from samples, not callback arrival")
        }
        // Reconstruct the archived B counters with injected wakeups. The first
        // timer is 12 chunks late; a later timer is 22 chunks late. The old
        // ten-chunk truncation skips 2 + 12 chunks (57,344 frames). The first
        // skip precedes source creation, while the later skip adds 1,024 ms to
        // each lane, doubling the deliberate 2,048 ms Others omission.
        func replay(discardLateSamples: Bool) -> (gaps: Int, skipped: Int) {
            let chunk = 4096, clock = SpectrogramFixtureClock(chunk:4096)
            var frames = 0, skipped = 0, gaps = 0
            var last = [Int?](repeating:nil,count:2)
            let wakeups = [12] + Array(13...100) + [122] + Array(123...200)
            for complete in wakeups {
                if discardLateSamples, complete-frames/chunk > 10 {
                    let resumed = (complete-10)*chunk
                    skipped += resumed-frames; frames = resumed
                }
                let elapsed = Double(complete*chunk)/48000 + 1e-9
                while frames < complete*chunk {
                    let end = clock.batchEnd(after:frames,at:elapsed)
                    require(end > frames && end-frames <= 10*chunk,"Bound catch-up work without skipping samples")
                    while frames < end {
                        for lane in 0..<2 where lane == 0 || !(150..<174).contains(frames/chunk) {
                            if let previous = last[lane] {
                                let missing = frames-previous-chunk
                                if missing >= 48000 { gaps += missing }
                            }
                            last[lane] = frames
                        }
                        frames += chunk
                    }
                }
            }
            return (gaps,skipped)
        }
        let old = replay(discardLateSamples:true), fixed = replay(discardLateSamples:false)
        require(old.skipped == 57344 && old.gaps == 196608,"Negative control reproduces archived 57,344 skipped frames and 4,096 ms total gap")
        require(fixed.skipped == 0 && fixed.gaps == 98304,"Catch-up preserves every frame: only the unchanged 2,048 ms deliberate gap remains")
        print("PASS archived B negative control: 4096 ms / 57344 skipped; fixed: 2048 ms / zero skipped, expectation unchanged")
        print("Injected sample-clock checks passed for4096/8192 frames; no future audio or whole-buffer retry")
    }
}
