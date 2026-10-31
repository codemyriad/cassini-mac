// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Bounded reads of an already-decoded, app-owned raw mono float scratch file.
enum EchoAudioLevels {
    static func measure(stream: FileHandle, sampleCount: Int, from startMs: Int64,
                        to endMs: Int64, offsetMs: Int64) throws -> Double? {
        guard startMs < endMs, sampleCount > 0 else { return nil }
        func frame(_ time: Int64) -> Int {
            Int(min(Double(sampleCount),max(0,(Double(time)-Double(offsetMs))*16)))
        }
        let first = frame(startMs), last = frame(endMs)
        guard first < last else { return nil }
        try stream.seek(toOffset:UInt64(first)*4)
        var remaining = last-first, sum = 0.0
        while remaining > 0 {
            let count = min(remaining,8192)
            let data = try stream.read(upToCount:count*4) ?? Data()
            guard data.count == count*4 else { throw CocoaError(.fileReadCorruptFile) }
            try data.withUnsafeBytes { bytes in
                for index in 0..<count {
                    let value = Double(bytes.loadUnaligned(fromByteOffset:index*4,as:Float.self))
                    guard value.isFinite else { throw CocoaError(.fileReadCorruptFile) }
                    sum += value*value
                }
            }
            remaining -= count
        }
        return 20*log10(max(1e-9/32768,sqrt(sum/Double(last-first))))
    }
}
