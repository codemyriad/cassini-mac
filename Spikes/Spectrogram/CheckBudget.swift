// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Pure CPU/RAM boundary checks; no AppKit, graphics, audio or devices.
@main enum CheckBudget {
    static func main() {
        func gates(_ mode:String="B",_ seconds:Double=60,analysis:Double=0.8,drawing:Double=3.5,
                   p95:Double=17.5,maximum:Double=50,late:UInt64=90,payload:Int=131072)->[String:Bool] {
            SpectrogramHostedBudget.evaluate(mode:mode,seconds:seconds,analysis:analysis,drawing:drawing,
                                             p95:p95,maximum:maximum,late:late,payload:payload)
        }
        precondition(gates().values.allSatisfy {$0})
        precondition(gates("D").values.allSatisfy {$0})
        precondition(gates("A",drawing:1.7,p95:33.4,maximum:90).values.allSatisfy {$0})
        precondition(gates(analysis:0.800001)["analysis"] == false)
        precondition(gates(drawing:3.500001)["drawing"] == false)
        precondition(gates("A",drawing:1.700001)["drawing"] == false)
        precondition(gates(p95:17.500001)["pacing"] == false)
        precondition(gates(maximum:50.000001)["pacing"] == false)
        precondition(gates(late:91)["late"] == false)
        precondition(gates("B",30,late:45)["late"] == true)
        precondition(gates("B",30,late:46)["late"] == false)
        precondition(gates(payload:131073)["logicalViewPayload"] == false)
        for mode in ["C","E"] {
            precondition(gates(mode,analysis:0,late:0).values.allSatisfy {$0})
            precondition(gates(mode,analysis:0.000001,late:0)["analysis"] == false)
            precondition(gates(mode,analysis:0,late:1)["late"] == false)
        }
        precondition(!gates("B",0).filter {$0.key != "logicalViewPayload"}.values.contains(true))
        print("PASS D36.2/D36.3 hosted boundaries, shared timeline denominator and hidden zero-work guards")
    }
}
