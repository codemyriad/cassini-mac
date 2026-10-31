// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// D36.2 (coordination e0e3124): hosted regression guards, not hardware targets.
/// Both lanes share a 50 Hz timeline. Count its steady-state slots once, rather
/// than multiplying the allowed lateness by lane or source-track count.
enum SpectrogramHostedBudget {
    static func steadyColumns(seconds:Double)->Double {floor(seconds*50)}
    static func evaluate(mode:String,seconds:Double,analysis:Double,drawing:Double,
                         p95:Double,maximum:Double,late:UInt64,payload:Int)->[String:Bool] {
        let hidden=mode == "C" || mode == "E"
        let columns=steadyColumns(seconds:seconds)
        let valid=seconds.isFinite && columns>0
        return ["analysis":valid && (hidden ? analysis == 0 : analysis <= 0.8),
                "drawing":valid && drawing <= (mode == "A" ? 1.0 : 3.5),
                "pacing":valid && (mode == "A" || hidden || (p95 <= 17.5 && maximum <= 50)),
                "late":valid && (hidden ? late == 0 : Double(late)/columns <= 0.03),
                "logicalViewPayload":payload >= 0 && payload <= 131072]
    }
}
