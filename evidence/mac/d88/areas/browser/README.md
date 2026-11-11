# Browser control and IPC event barriers

The area starts from main `5562b8b`. Current-main shared model fixture fixes are retained. Earlier source and full proof logs remain reachable through [#210 source](https://github.com/codemyriad/cassini-mac/tree/de512ad67b1a80c7baae418e3bacc94cf9b9bf3a), [#211 source](https://github.com/codemyriad/cassini-mac/tree/2e81a223e15d9e82373e790c8ec0802ee6af7473).

| Conversion | Regression case | Mutation |
| --- | --- | --- |
| First status belongs to its profile | `testProfilesWithSameTabStaySeparateAndWaitForTheirOwnFirstStatus` | [profile-first-status.patch](profile-first-status.patch) |
| Stopped calls remain stopped | `testAutomaticStartIsNotAnnouncedUntilItsAcknowledgementAndStopDoesNotRestart` | [stopped-call-barrier.patch](stopped-call-barrier.patch) |
| Shutdown joins folder creation | `testShutdownClosesAdmissionAndWaitsForAnInFlightFolderFactory` | [factory-drain.patch](factory-drain.patch) |
| Concurrent Stop and Quit share one drain | `testConcurrentAppStopsAndQuitShareOneNativeDrain` | [shared-finalization.patch](shared-finalization.patch) |
| Generated microphone frames precede source assertions | `testRealNativeProcessesRecordIndependentFilesAndStopOnlyTheirOwnCapture` | [microphone-pcm.patch](microphone-pcm.patch) |
| Permission cancellation waits for registered callbacks | `testRepeatedPageChangesCancelWaitersButKeepOnlyOnePendingOSRequest` | [permission-registration.patch](permission-registration.patch) |
| Old microphone callbacks cannot fail a replacement | `testRetryMePreservesSystemAndIgnoresFailureFromPreviousMic` | [stale-failure.patch](stale-failure.patch) |

Mutation failure excerpts are in [mutations.log](mutations.log). Apply a patch with `git apply --unidiff-zero` to reproduce it. Full local logs and the replay configuration are in `~/coordination/evidence/big-mac-d88/areas/browser`.

before — Executed 73 tests, with 0 failures (0 unexpected) in 21.868 (21.873) seconds; ✔ Test run with 0 tests passed after 0.001 seconds.
after — Executed 73 tests, with 0 failures (0 unexpected) in 21.360 (21.366) seconds; ✔ Test run with 0 tests passed after 0.001 seconds.
restored — Executed 73 tests, with 0 failures (0 unexpected) in 20.743 (20.749) seconds; ✔ Test run with 0 tests passed after 0.001 seconds.
