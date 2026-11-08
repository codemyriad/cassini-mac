// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Device-free, analytically generated 2-on/2-off rows at every subpixel phase.
@main enum CheckPixelOracle {
    static func main() {
        let width = 200, height = 32
        func image(phase: Double, solid: Bool = false, blank: Bool = false, half: Bool = false, opacity: Double = 0.40) -> [UInt8] {
            var rgba = [UInt8](repeating:246,count:width*height*4)
            for offset in stride(from:3,to:rgba.count,by:4) { rgba[offset] = 255 }
            for x in 0..<width {
                let previous = (x+3)%4 < 2 ? 1.0 : 0.0
                let current = x%4 < 2 ? 1.0 : 0.0
                let ink = blank || half && x >= width/2 ? 0 : solid ? 1 : previous*phase+current*(1-phase)
                let fade = min(1,Double(x)/32)
                for (channel,colour) in [29.0,29.0,31.0].enumerated() {
                    rgba[(16*width+x)*4+channel] = UInt8((246+(colour-246)*opacity*ink*fade).rounded())
                }
            }
            return rgba
        }
        func accepted(_ rgba: [UInt8]) -> Bool {
            let result = SpectrogramPixelOracle.measure(rgba,width:width,height:height)
            return (60...130).contains(result.coverage) && result.periodicity >= 0.45
        }
        for step in 0...64 { precondition(accepted(image(phase:Double(step)/64))) }
        let halfPhase = image(phase:0.5)
        let hardCount = stride(from:0,to:halfPhase.count,by:4).filter {
            halfPhase[$0] < 200 && halfPhase[$0+1] < 200 && halfPhase[$0+2] < 200
        }.count
        precondition(hardCount < 60, "Negative control must reproduce the old phase-sensitive failure")
        precondition(!accepted(image(phase:0,blank:true)))
        precondition(!accepted(image(phase:0,solid:true)))
        precondition(!accepted(image(phase:0,solid:true,opacity:0.20)))
        precondition(!accepted(image(phase:0.5,half:true)))
        print("PASS dotted-line coverage at 65 phases; old threshold fails; blank, solid and half-history controls rejected")
    }
}
