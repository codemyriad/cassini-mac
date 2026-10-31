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
        print("Injected sample-clock checks passed for4096/8192 frames; no future audio or whole-buffer retry")
    }
}
