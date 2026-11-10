# AWS Mac D88 setup/watcher helpers

Base main `9a22168`, Xcode 16.4, AWS Mac M4, 2026-11-10.

Fake retry-clock and installer actors now publish events after registering their
actual sleepers/blocked attempts. State publication uses Observation callbacks.
Installation waits on the same published state rather than yielding until a real
deadline. Retry values, cancellation, trigger coalescing, installer threading and
on-disk manifest assertions remain. No production source is changed.

WatcherTests.swift:21 is deliberately kept. Its five-second competing task returns
nil; only an actual FSEvent with the expected path can satisfy the test. The timeout
is a failure-only hang bound, not an absence/success window.

`before.log`: unchanged baseline suites pass. `after.log` and `restored.log`: 29
XCTest tests plus 4 Swift Testing installation/watcher tests pass. Removing the
coalesced follow-up attempt (`drop-coalesced.patch` / `.log`) fails the entered-second-
attempt event and the final count assertion. The two earlier compiler diagnostics
are retained: Swift 6.1 requires a main-actor observer object rather than the local
function's Sendable capture. The final helper compiles and passes.

Runs hold `~/.cassini-heavy.lock`, copy only changed Swift tests into disposable
`/tmp/cassini-aws-d88-before`, run `swift test --scratch-path
/tmp/cassini-aws-d88-before-build --jobs 4 --filter
'InstallationTests|BackgroundSetupTests|LibraryWatcherTests'`, and restore the files.
Exact-head full CI remains required before readiness.

## Checked bug classes

Reviewed `~/coordination/BUG-CLASSES.md`: 17 checked (actual registration/publication
events; watcher guard individually retained); 2 checked (off-main installer assertion
and main-actor progress while blocked); 15 checked (retry cancellation and classified
failure tests); 18 checked (base main). 19 pending exact-head CI. 1, 3–14 and 16 not
applicable to this test-only helper change.
