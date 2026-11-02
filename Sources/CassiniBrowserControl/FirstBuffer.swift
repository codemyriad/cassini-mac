// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import CassiniRecording

/// D58: a side has opened when its first buffer is admitted, within 3 s of its open attempt.
final class FirstBufferSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    private var waiters: [UUID:CheckedContinuation<Bool,Never>] = [:]
    var hasFired: Bool { lock.withLock { fired } }
    func fire() {
        let waiting: [CheckedContinuation<Bool,Never>] = lock.withLock {
            guard !fired else { return [] }
            fired = true; defer { waiters.removeAll() }; return Array(waiters.values)
        }
        for waiter in waiting { waiter.resume(returning:true) }
    }
    /// True once the first buffer arrived; false when `bound` returns first. Whichever comes
    /// first answers; the other never delays it.
    func wait(bound: @escaping @Sendable () async -> Void) async -> Bool {
        let id = UUID()
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool,Never>) in
            let ready: Bool = lock.withLock {
                if fired { return true }
                waiters[id] = continuation; return false
            }
            if ready { continuation.resume(returning:true); return }
            Task {
                await bound()
                let waiter = self.lock.withLock { self.waiters.removeValue(forKey:id) }
                waiter?.resume(returning:false)
            }
        }
    }
}

/// Forwards everything to a side's writer and signals its first admitted buffer.
final class FirstBufferWriter: RecordingSinkWriter {
    private let base: any RecordingSinkWriter
    private let signal: FirstBufferSignal
    init(_ base: any RecordingSinkWriter, signal: FirstBufferSignal) { self.base = base; self.signal = signal }
    var recordingProblem: String? { base.recordingProblem }
    func addTrack(id: String, label: String, kind: String, sampleRate: Int, channels: Int) throws {
        try base.addTrack(id:id,label:label,kind:kind,sampleRate:sampleRate,channels:channels)
    }
    func appendNative(id: String, pcm: Data, offsetMs: Double) throws {
        try base.appendNative(id:id,pcm:pcm,offsetMs:offsetMs); signal.fire()
    }
    func appendNative(id: String, pcm: Data, offsetMs: Double, gapKind: String) throws {
        try base.appendNative(id:id,pcm:pcm,offsetMs:offsetMs,gapKind:gapKind); signal.fire()
    }
    func padNative(id: String, frames: UInt64, channels: Int, rate: Double, offsetMs: Double, kind: String) throws {
        try base.padNative(id:id,frames:frames,channels:channels,rate:rate,offsetMs:offsetMs,kind:kind)
    }
    func finish(problem: String?) throws { try base.finish(problem:problem) }
    func finish(problem: String?, kind: String?) throws { try base.finish(problem:problem,kind:kind) }
    func reportLoss(id: String, droppedFrames: UInt64, gapFrames: UInt64) { base.reportLoss(id:id,droppedFrames:droppedFrames,gapFrames:gapFrames) }
}
