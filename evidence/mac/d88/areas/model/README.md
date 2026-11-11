# Model startup and browser setup completion

The area starts from main `5562b8b`. Current-main shared model fixture fixes are retained. Earlier source and full proof logs remain reachable through [#213 source](https://github.com/codemyriad/cassini-mac/tree/624ea6af713bf473aeedff685cbb787ae6c5bd65), [#214 source](https://github.com/codemyriad/cassini-mac/tree/30cf61dfdd0f3877b2d6f2185cdd9c9d21cb7da0).

| Conversion | Regression case | Mutation |
| --- | --- | --- |
| Retry clock registration | `testFakeClockRetryAndSuccessStopsTimer` | [retry-registration.patch](retry-registration.patch) |
| Activation during setup coalesces | `testEventsDuringAttemptCoalesceWithoutBlockingUIActor` | [activation-coalescing.patch](activation-coalescing.patch) |
| Stop completes retry cancellation | `testStopCancelsScheduledRetry` | [retry-cancellation.patch](retry-cancellation.patch) |
| Install completion publishes readiness | `testLaunchTriggerInstallsMissingManifestsWithoutConnectAction` | [installed-publication.patch](installed-publication.patch) |
| A stalled child exits through the manual deadline | `fixtureBootstrapWithoutAReadinessEventFailsAndReapsItsChild` | [manual-startup.patch](manual-startup.patch) |
| Malformed readiness remains a failure | `fixtureBootstrapReportsTheChildsErrorAndInvalidReadinessLine` | [invalid-readiness.patch](invalid-readiness.patch) |

Mutation failure excerpts are in [mutations.log](mutations.log). Apply a patch with `git apply --unidiff-zero` to reproduce it. Full local logs and the replay configuration are in `~/coordination/evidence/big-mac-d88/areas/model`.

before — Executed 29 tests, with 0 failures (0 unexpected) in 0.148 (0.150) seconds; ✔ Test run with 27 tests passed after 0.554 seconds.
after — Executed 29 tests, with 0 failures (0 unexpected) in 0.105 (0.107) seconds; ✔ Test run with 27 tests passed after 0.482 seconds.
restored — Executed 29 tests, with 0 failures (0 unexpected) in 0.150 (0.153) seconds; ✔ Test run with 27 tests passed after 0.575 seconds.
