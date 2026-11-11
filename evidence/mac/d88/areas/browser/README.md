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

All seven current mutations change production decisions, never observers or fixtures. Their tests fail behavioral assertions without expectation timeouts or leaked continuations; see [mutations.log](mutations.log). The earlier four seam-only mutants are superseded.

Review fix: the shutdown observer is private under the broker lock and is snapshotted before invocation outside that lock. Its test clears it after registration and in cleanup. Stop callbacks and OS permission continuations are arrays drained on release, including late Stop callbacks. Permission registration is observed after reusing a request or entering the new OS task, so cancellation cannot hide a duplicate request before its driver starts. Completion/failure observers are cleared after fulfillment; late microphone permission handling is explicitly awaited.

The current 73-case slice passes before, after and restored. The four reviewed mutants remove real folder-drain membership, finalization deduplication, the requested microphone plan, or OS-request sharing. Their failures respectively check saved/active state, native Stop count, microphone selection/tracks, and authorization count. None of the seven logs contains an expectation timeout or continuation misuse.

Apply one patch at a time with `git apply --unidiff-zero`. A full private replay is [replay.py](replay.py): select Xcode 16.4, export its SDKROOT, then run `D88_EVIDENCE_DIR=/tmp/d88-browser-review ~/bin/heavy-run python3 evidence/mac/d88/areas/browser/replay.py`. Full logs, source snapshots and results are in `~/coordination/evidence/big-mac-d88/review-210/`.
