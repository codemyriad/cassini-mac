// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
@main struct CheckScrollRate {
 static func main() {
  var clock = SpectrogramDisplayClock()
  _ = clock.advance(nowMs:0);precondition(clock.presentationRate == 1)
  clock.observe(columnMs:0,arrivalMs:300)
  _ = clock.advance(nowMs:300);precondition(clock.presentationRate == 0.5)
  _ = clock.advance(nowMs:1000);precondition(clock.presentationRate == 1)
  _ = clock.advance(nowMs:6000);precondition(clock.presentationRate == 1.02)
  _ = clock.advance(nowMs:20000);precondition(clock.presentationRate == 1)
  print("PASS exact growing, settled and shrinking clock segment rates")
 }
}
