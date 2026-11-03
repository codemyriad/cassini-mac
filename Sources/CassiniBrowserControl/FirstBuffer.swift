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
