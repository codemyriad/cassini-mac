# Shared-model CI blocker on playback PR #212

Observed 2026-11-10 16:20 UTC. No rerun was requested or performed.

- Tested PR head: `ac49a7503d35c32837b2a93605028f6525e6fc95`.
- CI run: https://github.com/codemyriad/cassini-mac/actions/runs/42836646744
- Failed job: https://github.com/codemyriad/cassini-mac/actions/runs/42836646744/job/129955557532
- Failed step: Test (CassiniKit tests and conformance).
- Only two reported issues: `ModelSupersessionTests.replacementIsRecheckedAfterItsLockAndCancellationKeepsOld`, cancel=false and cancel=true, line 93. Both expected `XCTWaiterResult.completed` and observed rawValue 2 (timed out).
- The changed `SessionPlaybackTests.abandonedPreparationIsCancelledWithItsOwner` passed in 0.005 s. Its entire suite passed.
- The Swift Testing run reported 540 tests, two issues. Several unrelated test durations in the same log were 60–71 seconds; this alone does not establish a flake or root cause.

Source review: the test holds a real replacement revision flock, starts `removeSuperseded`, then awaits the internal failed-lock observer. `ModelDownloader.removalLock` has an existing five-second real deadline and checks it before calling the observer after a busy flock. Scheduling/deadline interaction is a candidate for investigation, not a proven CI diagnosis. Do not inflate the bounds or rerun the red job.

`ModelSupersessionTests` is outside the assigned startup fixture row (`ModelDownloaderTests`, `Fixtures/server.py`). The brief says ONLY the assigned rows, with the rest owned by drmeyers. Ownership clarification has been requested asynchronously. The other PR readiness checks continue; #212 stays draft and #215 readiness remains held behind #210–#214.
