// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Pure CPU/RAM boundary checks; no AppKit, graphics, audio or devices.
@main enum CheckBudget {
    static func main() {
        func gates(_ mode:String="B",_ seconds:Double=60,analysis:Double=0.8,drawing:Double=3.5,
                   p95:Double=17.5,maximum:Double=50,samples:UInt64=3000,late:UInt64=90,payload:Int=131072)->[String:Bool] {
            SpectrogramHostedBudget.evaluate(mode:mode,seconds:seconds,analysis:analysis,drawing:drawing,
                                             p95:p95,maximum:maximum,frameCPUSamples:samples,late:late,payload:payload)
        }
        precondition(gates().values.allSatisfy {$0})
        precondition(gates("D").values.allSatisfy {$0})
        precondition(gates("A",drawing:1.7,p95:33.4,maximum:90).values.allSatisfy {$0})
        precondition(gates(analysis:0.800001)["analysis"] == false)
        precondition(gates(drawing:3.500001)["drawing"] == false)
        precondition(gates("A",drawing:1.700001)["drawing"] == false)
        precondition(gates(p95:17.500001)["frameWork"] == false)
        precondition(gates(maximum:100)["frameWork"] == true)
        precondition(gates(maximum:100.000001)["frameWork"] == false)
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
        precondition(gates(samples:0)["frameWork"] == false)
        // A delayed host callback can have a 121.580 ms wall interval while
        // doing only 1 ms of main-thread work. Wall timestamps are deliberately
        // absent from the input. A real 101 ms CPU interval must still fail.
        var cpu = SpectrogramFrameCPU()
        cpu.record(through:0)
        for n in 1...100 { cpu.record(through:UInt64(n)*1_000_000) }
        precondition(cpu.count == 100 && cpu.valid && cpu.p95Ms == 1 && cpu.maximumMs == 1)
        precondition(gates(p95:cpu.p95Ms,maximum:cpu.maximumMs,samples:cpu.count)["frameWork"] == true)
        cpu.record(through:201_000_000)
        precondition(cpu.maximumMs == 101)
        precondition(gates(p95:cpu.p95Ms,maximum:cpu.maximumMs,samples:cpu.count)["frameWork"] == false)
        cpu.record(through:0); precondition(!cpu.valid)
        let reset = SpectrogramFrameCPU(); precondition(reset.count == 0 && reset.p95Ms == 0)
        print("PASS D88 CPU frame-work histogram and unchanged D36.2/D36.3/D36.4 hosted boundaries, shared timeline denominator and hidden zero-work guards")
    }
}
