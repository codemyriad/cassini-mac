// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Coverage of the light row's 40%-opacity ink, in equivalent full-dot pixels.
/// Linear filtering conserves contrast while moving it between adjacent pixels;
/// counting pixels below a fixed colour threshold does not.
enum SpectrogramPixelOracle {
    static func dottedLineCoverage(_ rgba: [UInt8], width: Int, height: Int) -> Double {
        precondition(width > 0 && height > 0 && rgba.count == width*height*4)
        var background = [Double](repeating:0,count:3)
        for x in 0..<width {
            for channel in 0..<3 { background[channel] += Double(rgba[x*4+channel])/Double(width) }
        }
        let ink = [29.0,29.0,31.0] // Approved light row ink #1d1d1f, alpha 0.40.
        let fullDotContrast = zip(background,ink).reduce(0) { $0+($1.0-$1.1)*0.40 }
        guard fullDotContrast > 0 else { return .infinity }
        var contrast = 0.0
        for offset in stride(from:0,to:rgba.count,by:4) {
            for channel in 0..<3 { contrast += max(0,background[channel]-Double(rgba[offset+channel])) }
        }
        return contrast/fullDotContrast
    }
}
