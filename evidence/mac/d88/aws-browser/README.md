# AWS Mac D88 Browser broker/start/permissions row

Base main `9a22168`, Xcode 16.4 on AWS Mac M4, 2026-11-10.

- Folder creation remains behind an explicit release semaphore until shutdown
  registers its real DispatchGroup wait. Cleanup removes that observation hook.
- All 21 concurrent finalizers register against the same held native drain before
  release; the fixture still sends a late duplicate reply and asserts one drain.
- Generated microphone PCM is flushed before publishing a per-capture event.
  Tests still inspect frame counts, capture identity, source slots, and saved state.
- OS permission requests and shared authorization waiters expose entered/completed
  events. Tests cancel/restore/stop while the request remains explicitly held.
- Failure callbacks expose completion after their actual queued handler settles;
  stale-generation and current-side assertions run after that fence.

The small internal observers report completion or registration; they do not
release work, choose outcomes, or change default delays. All audio is synthetic;
no GUI, microphone, or system capture device is opened.

## Evidence

`before.log`: unchanged main, 73 selected tests pass, including all 61 browser-row
tests. `after.log` and `restored.log`: all 61 pass. `stale-failure.patch` / `.log`:
removing the generation guard fails the expected failed-side, stop-count and saved
state assertions. `initial-failed.log` records the first local run's hook-lifetime
mistake (cleanup fulfilled an expectation twice); clearing the hook after the
intended shutdown fixes it. The subsequent complete suite passes.

Runs use `~/.cassini-heavy.lock`, staging only this branch's changed Swift files
into `/tmp/cassini-aws-d88-before` and restoring them afterward, with scratch path
`/tmp/cassini-aws-d88-before-build`. Command: `swift test --jobs 4 --filter
'AudioBrokerTests|InputLifecycleTests|D52SourceOutcomeTests'`. Exact-head full CI is
required before readiness. Baseline suite wall time and event wait durations are
diagnostic only, never pass conditions.

## Checked bug classes

Reviewed `~/coordination/BUG-CLASSES.md` (D87): 17 checked via real event gates; 14
checked with flushed PCM and completed native drains; 15 checked via cancellation,
late errors and saved-state assertions; 18 checked (base main). 19 pending exact-head
CI. 1–13 and 16 not applicable: no transcript/UI/format/storage policy changes.
