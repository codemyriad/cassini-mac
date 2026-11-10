import Foundation
import Testing
import XCTest

/// Diagnostic-only probe: run with LIBDISPATCH_COOPERATIVE_POOL_STRICT=1.
struct SupersessionPoolProbeTests {
    @Test(.serialized,arguments:[false,true]) func heldPoolCannotBlockReplacementFixture(_ cancel: Bool) async throws {
        let controller = SupersessionProbeExecutor()
        try await withTaskExecutorPreference(controller) {
            let entered = DispatchSemaphore(value:0), release = DispatchSemaphore(value:0)
            let blocker = Task.detached {
                holdCooperativeWorker(entered:entered,release:release)
            }
            defer { release.signal(); blocker.cancel() }
            let observed = await withCheckedContinuation { continuation in
                DispatchQueue.global().async { continuation.resume(returning:entered.wait(timeout:.now()+10)) }
            }
            try #require(observed == .success,"The global cooperative worker must enter its explicit hold")
            try await SupersessionPoolProbeHooks.$onLockWait.withValue({ release.signal() }) {
                try await ModelSupersessionTests().replacementIsRecheckedAfterItsLockAndCancellationKeepsOld(cancel)
            }
        }
    }
}

// Deliberate synchronous hold to simulate an unavailable cooperative worker.
private func holdCooperativeWorker(entered: DispatchSemaphore, release: DispatchSemaphore) {
    entered.signal(); release.wait()
}

private final class SupersessionProbeExecutor: TaskExecutor {
    private let queue = DispatchQueue(label:"CassiniSupersession.probe-controller")
    func enqueue(_ ownedJob: consuming ExecutorJob) {
        let job = UnownedJob(ownedJob)
        queue.async { job.runSynchronously(on:self.asUnownedTaskExecutor()) }
    }
}

// The verification recipe calls this only from the actual failed-flock observer.
enum SupersessionPoolProbeHooks {
    @TaskLocal static var onLockWait: (@Sendable () -> Void)?
}
