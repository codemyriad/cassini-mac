// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Coverage of the light row's 40%-opacity ink, in equivalent full-dot pixels.
/// Linear filtering conserves contrast while moving it between adjacent pixels;
/// counting pixels below a fixed colour threshold does not.
enum SpectrogramPixelOracle {
    struct Measurement {
        let coverage: Double
        let periodicity: Double
    }
    static func measure(_ rgba: [UInt8], width: Int, height: Int) -> Measurement {
        precondition(width > 0 && height > 0 && rgba.count == width*height*4)
        var background = [Double](repeating:0,count:3)
        for x in 0..<width {
            for channel in 0..<3 { background[channel] += Double(rgba[x*4+channel])/Double(width) }
        }
        let ink = [29.0,29.0,31.0] // Approved light row ink #1d1d1f, alpha 0.40.
        let fullDotContrast = zip(background,ink).reduce(0) { $0+($1.0-$1.1)*0.40 }
        guard fullDotContrast > 0 else { return .init(coverage:.infinity,periodicity:0) }
        var contrast = 0.0, phases = [Double](repeating:0,count:4)
        for offset in stride(from:0,to:rgba.count,by:4) {
            let phase = ((offset/4)%width)%4
            for channel in 0..<3 {
                let value = max(0,background[channel]-Double(rgba[offset+channel]))
                contrast += value; phases[phase] += value
            }
        }
        // The 2-on/2-off row has a four-column harmonic. Its magnitude/ink is
        // 0.5...sqrt(0.5) through a complete linear-filter phase cycle. A solid
        // line has none, regardless of its opacity. Leave margin for rounding
        // and the production fade at the left edge.
        let harmonic = hypot(phases[0]-phases[2],phases[1]-phases[3])
        return .init(coverage:contrast/fullDotContrast,periodicity:contrast > 0 ? harmonic/contrast : 0)
    }
}
