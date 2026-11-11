# AWS Mac D88 playback cancellation fixture

Base main `9a22168`, Xcode 16.4, AWS Mac M4, 2026-11-10.

The abandoned-preparation test now waits for its builder to enter a gate before
dropping the owner. It requires actual cancellation delivery while the builder is
held, then explicitly releases preparation and awaits the original task. It keeps
the weak-owner, task-cancelled and no-playback assertions. No production changes.
The five-second expectation deadlines only fail missing events; release is explicit
so a cancellation mutation cannot leave the fixture sleeping for 60 seconds.

`before.log`: baseline selected areas, including all 33 SessionPlaybackTests pass.
`after.log` / `restored.log`: all 33 pass. `owner-cancel.patch` / `.log`: removing
PreparationLifetime's cancellation fails both the task-cancelled and delivered-event
assertions. All timelines and transport samples are synthetic.

Runs hold `~/.cassini-heavy.lock`, copy this branch's changed Swift test into the
disposable `/tmp/cassini-aws-d88-before` checkout, run `swift test --scratch-path
/tmp/cassini-aws-d88-before-build --jobs 4 --filter SessionPlaybackTests`, and restore
it afterward. Exact-head full CI remains required before readiness.

## Checked bug classes

Reviewed `~/coordination/BUG-CLASSES.md`: 17 checked with entered/cancel/release gates;
15 checked via cancellation assertions; 18 checked (base main). 19 pending exact-head
CI. 1–14 and 16 not applicable to this test-only preparation fixture.
