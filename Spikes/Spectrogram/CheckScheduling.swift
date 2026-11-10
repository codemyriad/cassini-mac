// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Darwin
import CassiniRecording
import CassiniSpectrogram

/// Real SDK input/analysis/display ordering with a virtual media clock. Host
/// descheduling never changes the timestamps or satisfies an assertion.
private final class ScheduleClock: @unchecked Sendable {
    private let lock = NSLock()
    private var entry = 0.0, ready = 0.0, first = true
    func packet(entry: Double, ready: Double) {
        lock.lock(); defer { lock.unlock() }
        self.entry = entry; self.ready = ready; first = true
    }
    func read() -> Double {
        lock.lock(); defer { lock.unlock() }
        if first { first = false; return entry }
        return ready
    }
}

@main enum CheckScheduling {
    struct Observation: Encodable {
        let chunkFrames: Int, sourceTracks: Int, analysisDelayMs: Double, displayLeadMs: Double, visible: Bool
        let steadyMediaFrames: Int, analyzedFrames: UInt64, lateColumns: UInt64, droppedBuffers: UInt64, droppedColumns: UInt64
        let retainedTracks: Int, lateGate: Bool
    }
    struct Report: Encodable {
        let virtualClockOnly = true, audioDevicesOpened = false
        let gates: [String:Bool], cases: [Observation], cpuSecondsDiagnostic: Double
    }
    static func frame(_ session: SpectrogramSession, at ms: Double) async -> SpectrogramSession.Frame {
        await withCheckedContinuation { continuation in
            session.requestFrame(nowMs:ms) { continuation.resume(returning:$0) }
        }
    }
    static func trace(chunk: Int, tracks: Int, analysisMs: Double, leadMs: Double = 0,
                      visible: Bool = true) async -> Observation {
        let clock = ScheduleClock(), session = SpectrogramSession(clock:{ clock.read() })
        session.setVisible(visible)
        let sources = (0..<tracks).map {
            RecordedPCMSource(id:"track-\($0)",kind:$0 == 0 ? "microphone":"remote",sampleRate:48000,channels:1,startOffsetMs:0)
        }
        let pcm = Data(repeating:0,count:chunk*2)
        var packet = 0, baselinePacket = 0, baselineLate: UInt64 = 0, baselineAnalysis: UInt64 = 0
        var last: SpectrogramSession.Frame?
        // Five seconds of virtual warm-up, then sixty seconds of media work.
        for tick in 0...3900 {
            let now = Double(tick)*1000/60
            while 150+Double((packet+1)*chunk)/48 <= now {
                let ready = 150+Double((packet+1)*chunk)/48
                for source in sources {
                    clock.packet(entry:ready-analysisMs,ready:ready)
                    session.offer(source:source,pcm:pcm,offsetMs:Double(packet*chunk)/48)
                    _ = await frame(session,at:ready) // Actual analysis-queue completion.
                }
                packet += 1
            }
            let result = await frame(session,at:now+(tick > 300 ? leadMs:0)); last = result
            if tick == 300 {
                baselineLate = result.lateColumns; baselineAnalysis = result.analyzedFrames; baselinePacket = packet
            }
        }
        let result = last!, late = result.lateColumns-baselineLate, samples = (packet-baselinePacket)*chunk
        return .init(chunkFrames:chunk,sourceTracks:tracks,analysisDelayMs:analysisMs,displayLeadMs:leadMs,visible:visible,
                     steadyMediaFrames:samples,analyzedFrames:result.analyzedFrames-baselineAnalysis,lateColumns:late,
                     droppedBuffers:result.droppedBuffers,droppedColumns:result.droppedColumns,retainedTracks:result.retainedTracks,
                     lateGate:SpectrogramHostedBudget.latePasses(mode:visible ? "D":"E",seconds:Double(samples)/48000,late:late))
    }
    static func main() async {
        let start = clock_gettime_nsec_np(CLOCK_PROCESS_CPUTIME_ID)
        let native = await trace(chunk:4096,tracks:2,analysisMs:0)
        let browser = await trace(chunk:8192,tracks:5,analysisMs:30)
        let early = await trace(chunk:8192,tracks:5,analysisMs:30,leadMs:1000)
        let hidden = await trace(chunk:8192,tracks:5,analysisMs:30,visible:false)
        let gates = [
            "nativeSteadyLateZero": native.lateGate && native.lateColumns == 0,
            "browserSteadyLateZero": browser.lateGate && browser.lateColumns == 0,
            "lateBudgetRejectsEarlyRelease": !early.lateGate && early.lateColumns > 0,
            "hiddenZeroWork": hidden.lateGate && hidden.lateColumns == 0 && hidden.analyzedFrames == 0 && hidden.retainedTracks == 0,
            "noDrops": [native,browser].allSatisfy { $0.droppedBuffers == 0 && $0.droppedColumns == 0 },
            "realAnalysis": native.analyzedFrames > 0 && browser.analyzedFrames > 0 && native.retainedTracks == 2 && browser.retainedTracks == 5
        ]
        let report = Report(gates:gates,cases:[native,browser,early,hidden],
                            cpuSecondsDiagnostic:Double(clock_gettime_nsec_np(CLOCK_PROCESS_CPUTIME_ID)-start)/1e9)
        do {
            FileHandle.standardOutput.write(try JSONEncoder().encode(report)+Data([10]))
            if !gates.values.allSatisfy({ $0 }) { exit(1) }
        } catch {
            FileHandle.standardError.write(Data("Scheduling report failed: \(error)\n".utf8)); exit(1)
        }
    }
}
