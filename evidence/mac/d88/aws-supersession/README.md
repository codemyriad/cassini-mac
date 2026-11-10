# Model supersession shared CI blocker — work in progress

Coordinator explicitly assigned this blocker to aws-mac after #212 CI failed.
Failed job: https://github.com/codemyriad/cassini-mac/actions/runs/42836646744/job/129955557532
Both `replacementIsRecheckedAfterItsLockAndCancellationKeepsOld` variants timed
out at line 93; the changed playback cancellation test passed. The CI test blob
`951c35519d4a349d59533954442e68827b3b81b9` matches the local baseline exactly.

Candidate fix: isolate the fixture controller and its unstructured removal task
on a dedicated DispatchQueue task executor. This applies only to the test; the
production five-second removal-lock deadline and the test ten-second guard remain.
Default actors honor explicit task-executor preference (Swift 6, SE-0417):
https://github.com/swiftlang/swift-evolution/blob/main/proposals/0417-task-executor-preference.md

`pool-probe.swift` is a diagnostic-only test copied into the disposable baseline
checkout by `verify.py`. With `LIBDISPATCH_COOPERATIVE_POOL_STRICT=1`, it holds a
cooperative worker behind an explicit release semaphore while a separate queue
runs the existing real-flock fixture. The baseline must reproduce the missing
event failure and the fix must pass. A separate mutation removes replacement
hash revalidation to prove corruption/old-copy retention assertions still fail.
No real sleeps, elapsed pass assertions, timeout inflation or CI reruns are used.

Verification is queued under the shared mkdir lock. Results are not yet claimed.
Historical recipe paths refer to this AWS Mac; adapt paths when restoring.
