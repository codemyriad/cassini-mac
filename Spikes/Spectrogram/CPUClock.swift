// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Darwin
func cpu() -> Double {
    var usage=rusage();getrusage(RUSAGE_SELF,&usage)
    return Double(usage.ru_utime.tv_sec+usage.ru_stime.tv_sec)+Double(usage.ru_utime.tv_usec+usage.ru_stime.tv_usec)/1e6
}
let count=50000
var reports:[[String:Any]]=[]
for (name,clock) in [("thread-cpu",CLOCK_THREAD_CPUTIME_ID),("uptime",CLOCK_UPTIME_RAW)] {
    let began=cpu(),wall=ProcessInfo.processInfo.systemUptime
    var checksum:UInt64=0
    for _ in 0..<count {checksum &+= clock_gettime_nsec_np(clock)}
    let seconds=cpu()-began
    reports.append(["clock":name,"reads":count,"cpuSeconds":seconds,"wallSeconds":ProcessInfo.processInfo.systemUptime-wall,"cpuMicrosecondsPerRead":seconds*1e6/Double(count),"checksum":checksum])
}
FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject:reports,options:[.sortedKeys])+Data([10]))
