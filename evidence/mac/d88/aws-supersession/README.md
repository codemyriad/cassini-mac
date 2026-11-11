# Supersession fixture cooperative-pool independence

Coordinator assigned the shared ModelSupersessionTests blocker to aws-mac.
CI #212: https://github.com/codemyriad/cassini-mac/actions/runs/42836646744/job/129955557532
CI #211 and #214 report the same two failures. The test blob
`951c35519d4a349d59533954442e68827b3b81b9` is identical to the local baseline.
The cancellation playback test itself passed in CI.

The original fixture starts an unstructured task on Swift's shared cooperative
pool while holding a real replacement revision flock and waiting for its failed-
lock observer. A parked cooperative worker reproduces the original line-93
failure for both cancellation variants. The fix keeps the controller and the
removal task on a test-owned task executor backed by a dispatch queue, and uses a
plain dispatch worker for the XCTest event wait. This leaves the production
five-second removal bound and the fixture ten-second hang guard unchanged.
No production code, fixture data, assertions, or app deployment target change.

Default actors honor explicit task-executor preference (Swift 6, SE-0417):
https://github.com/swiftlang/swift-evolution/blob/main/proposals/0417-task-executor-preference.md
A tiny test executor supports macOS 15; using DispatchQueue's built-in conformance
would incorrectly require macOS 15.4.

## Controlled proof

`pool-probe.swift` is a diagnostic-only test copied into a disposable checkout by
`verify.py`. It runs the existing fixture on a separate controller while explicitly
holding a cooperative worker. `LIBDISPATCH_COOPERATIVE_POOL_STRICT=1` applies only
to the test helper, not SwiftPM's compiler/planner. Cases run serially so they do
not compete for the single diagnostic worker. A TaskLocal callback is injected
only into the actual failed-flock observer and releases the held pool at that
point; it cannot synthesize the event, unlock the revision, or choose an outcome.
The remainder of the original cancellation/hash/retention assertions still runs.

- `before-held-pool.log`: both original parameter cases fail the actual line-93
  event assertion, reproducing the missing-event failure under controlled gating.
- `after-held-pool.log`: both parameter cases pass with the test executor fix.
- `after-model-supersession.log`: all seven ordinary supersession tests pass.
- `skip-revalidation.patch` / `.log`: omitting actual replacement hash validation
  fails the expected-hash-error and old-copy-retention assertions. Cancellation
  coverage remains intact.
- `restored.log`: all eight ordinary/probe tests pass after restoring production
  source. Probe and production edits are removed from the disposable baseline.

Xcode 16.4, AWS Mac M4. All fixture bytes are generated local model metadata; no
network, GUI or audio device is used. Every run holds `mkdir ~/.aws-heavy.lock`
and the earlier local flock. Child process groups have independent failure-only
hang bounds. Earlier compile/loader diagnostics, an overly broad initial probe
hold, and the coordinator-requested interruption are preserved as diagnostic
history; none are counted as successful tests or baseline assertion evidence.

## Checked bug classes

Reviewed cassini-ux main `1e8a722060c3f014c67fa4eff13c454307cc31ea`,
`review/BUG-CLASSES.md`: 17 checked with explicit holds and real flock events;
15 checked with the original CancellationError/hash distinctions; 16 checked
with retained-old-copy assertions and the revalidation mutation. 18 checked:
base main, no dependency on another draft. 19 pending exact-head CI on the PRs
that carry this fixture fix. Other classes are not applicable to this test-only
executor change.

Complete setup/loader/probe history is preserved on the standalone proof branch at `6ed212b` (`test/d88-aws-supersession-events`). This PR carries the final evidence and its own row-local run.
