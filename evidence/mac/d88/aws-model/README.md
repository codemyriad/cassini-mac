# AWS Mac D88 model fixture startup

Base main `9a22168`, Xcode 16.4, AWS Mac M4, 2026-11-10.

The intentionally stalled bootstrap test previously passed after 0.1 seconds of
real silence. Its Python child now announces `startup-held` immediately before
blocking on stdin without publishing a URL. The parent consumes that control event
and the test explicitly expires an injected startup clock. It requires exactly one
expiration and proves that this deadline, rather than the independent real hang
bound, caused failure. Child-reaping and temporary-folder cleanup assertions remain.

Normal starts keep their ten-second default guard and real clock. URL readiness,
child exits, registered diagnostic signal handling, prefix acknowledgements, stalled
transfer cancellation, complete byte counts and atomic install/removal tests retain
their existing event gates. No downloader production source is changed. Local data
is the generated model-contract fixture, served only over loopback with DNS forbidden.

`before.log`, `after.log` and `restored.log`: all 26 ModelDownloaderTests pass.
`false-ready.patch` / `.log`: replacing the stalled event with a premature valid-looking
URL makes the missing-readiness test fail (Server was incorrectly admitted).

Runs hold `~/.cassini-heavy.lock`, stage only the changed Swift test and Python
fixture into disposable `/tmp/cassini-aws-d88-before`, run `swift test --scratch-path
/tmp/cassini-aws-d88-before-build --jobs 4 --filter ModelDownloaderTests`, then restore
both files. Mutation resources are copied by SwiftPM before execution. Exact-head
full CI remains required before readiness.

## Checked bug classes

Reviewed `~/coordination/BUG-CLASSES.md`: 17 checked with child event/manual startup
clock; 14 checked by preserved complete-byte/prefix tests; 15 checked by cancellation,
bootstrap error and cleanup coverage; 16 checked by existing atomic install/lock tests;
18 checked (base main). 19 pending exact-head CI. 1–13 not applicable to this fixture-
only change.

## Manual deadline review follow-up

The bootstrap error records which exit the fixture actually took. The real hang
bound wins if both clocks have expired. The stalled test requires the
manual-deadline reason and keeps its child and directory cleanup checks.

A Swift probe compiled the bootstrap reader and ran the actual Python
`no-ready` fixture. At reviewed head `c2777e51`, disabling both manual exit checks
still satisfied the old assertion after the real hang bound. The fixed probe
reports `startupDeadline`. Applying `ignore-manual-deadline.patch` makes the
fixed assertion reject `hangBound`. See `deadline-review.log`. Production
downloader code is outside this change. D87 #17 is covered by the failed
mutation. D87 #19 requires CI on the follow-up commit.
