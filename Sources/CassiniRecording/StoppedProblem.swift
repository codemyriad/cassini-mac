// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import CassiniKit

extension RecordingManifest {
    /// D69.2: hide writer diagnostics without hiding a real gap whose warning D69
    /// suppressed. Shared by owned captures and the standalone browser host.
    public var stoppedProblem: String? {
        guard let problem else { return nil }
        let stripped = WriterLoss.strip(problem)
        // Ordinary browser jumps already have the writer's generic warning. Never
        // relabel, duplicate or otherwise alter it when no writer sentence was removed.
        guard stripped.count > 0 else { return problem }
        let generic = "Some audio is missing: the recording has a gap of at least one second."
        let hostSuffix = "ms of host-time gap; the timeline contains silence."
        guard !stripped.rest.contains(generic), !stripped.rest.contains(hostSuffix) else { return stripped.rest }

        var nativeMs: [String:Double] = [:], significantNative: Set<String> = [], significantGap = false
        for track in tracks where track.sampleRate > 0 {
            let rate = Double(track.sampleRate), native = ["microphone","system"].contains(track.kind)
            var listed = 0.0
            for gap in track.gaps ?? [] where ["jump","input"].contains(gap.kind) {
                let frames = gap.frames.map { Double($0) } ?? (gap.durationMs ?? 0) * rate / 1000
                listed += frames
                if frames >= rate { significantGap = true }
                // A browser jump is never native host time. Keep microphone and
                // system durations separate, including multiple spans of one side.
                if native, gap.kind == "input" {
                    nativeMs[track.kind,default:0] += frames * 1000 / rate
                    if frames >= rate { significantNative.insert(track.kind) }
                }
            }
            // Missing ranges or overflow can hide a long gap, but cannot establish
            // its kind or an exact host-time duration. Use the generic warning.
            if track.gaps == nil || track.gaps?.contains(where: { $0.kind == "overflow" }) == true {
                if Double(track.gapFrames ?? 0) - listed >= rate { significantGap = true }
            }
        }
        var warnings: [String] = []
        for kind in ["microphone","system"] where significantNative.contains(kind) {
            guard let ms = nativeMs[kind], ms.isFinite, ms < Double(Int64.max) else { continue }
            let warning = "Recording saved with \(Int64(ms.rounded())) ms of host-time gap; the timeline contains silence."
            if !warnings.contains(warning) { warnings.append(warning) }
        }
        if warnings.isEmpty, significantGap { warnings.append(generic) }
        let shown = ([stripped.rest] + warnings).filter { !$0.isEmpty }.joined(separator:" ")
        return shown.isEmpty ? nil : shown
    }
}
