// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import CassiniRecording

/// D58: a side has opened when its first buffer is admitted, within 3 s of its open attempt.
/// Admission and expiry are one atomic, terminal decision (#120 r3): whichever comes first
/// wins for good, so a late buffer can't open a side whose bound already passed, and an
/// expired side admits nothing more.
final class FirstBufferSignal: @unchecked Sendable {
    private enum State { case waiting, opened, expired }
    private let lock = NSLock()
    private var state = State.waiting
    private var waiters: [UUID:CheckedContinuation<Bool,Never>] = [:]
    var hasFired: Bool { lock.withLock { state == .opened } }
    var hasExpired: Bool { lock.withLock { state == .expired } }
    /// A first buffer arrived: true if it opens the side, false if the bound already passed.
    @discardableResult func admit() -> Bool { settle(.opened) }
    /// The bound passed: true if the side never opened (now expired for good).
    @discardableResult func expire() -> Bool { settle(.expired) }
    private func settle(_ outcome: State) -> Bool {
        let (won, waiting): (Bool,[CheckedContinuation<Bool,Never>]) = lock.withLock {
            guard state == .waiting else { return (state == outcome,[]) }
            state = outcome; defer { waiters.removeAll() }; return (true,Array(waiters.values))
        }
        for waiter in waiting { waiter.resume(returning:outcome == .opened) }
        return won
    }
    /// True once the first buffer was admitted; false once the bound passed first. The decision
    /// is the signal's own, so every waiter sees the same answer.
    func wait(bound: @escaping @Sendable () async -> Void) async -> Bool {
        let id = UUID()
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool,Never>) in
            let settled: Bool? = lock.withLock {
                if state != .waiting { return state == .opened }
                waiters[id] = continuation; return nil
            }
            if let settled { continuation.resume(returning:settled); return }
            Task { await bound(); self.expire() }
        }
    }
}
