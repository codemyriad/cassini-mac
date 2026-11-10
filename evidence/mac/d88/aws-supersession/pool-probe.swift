import Foundation
import Testing
import XCTest

/// Diagnostic-only probe: run with LIBDISPATCH_COOPERATIVE_POOL_STRICT=1.
struct SupersessionPoolProbeTests {
    @Test(arguments:[false,true]) func heldPoolCannotBlockReplacementFixture(_ cancel: Bool) async throws {
        let controller = DispatchQueue(label:"CassiniSupersession.probe-controller")
        try await withTaskExecutorPreference(controller) {
            let entered = DispatchSemaphore(value:0), release = DispatchSemaphore(value:0)
            let blocker = Task.detached {
                entered.signal()
                release.wait()
            }
            defer { release.signal(); blocker.cancel() }
            let observed = await withCheckedContinuation { continuation in
                DispatchQueue.global().async { continuation.resume(returning:entered.wait(timeout:.now()+10)) }
            }
            try #require(observed == .success,"The global cooperative worker must enter its explicit hold")
            try await ModelSupersessionTests().replacementIsRecheckedAfterItsLockAndCancellationKeepsOld(cancel)
        }
    }
}
