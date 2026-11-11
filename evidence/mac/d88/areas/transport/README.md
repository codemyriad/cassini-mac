# Transport discovery, framing and publication

The area starts from main `5562b8b`. Current-main shared model fixture fixes are retained. Earlier source and full proof logs remain reachable through [#215 source](https://github.com/codemyriad/cassini-mac/tree/d2660d4ab1a289cdbe6fcd9ee3a55171e039cdff).

| Conversion | Regression case | Mutation |
| --- | --- | --- |
| Discovery retires stale publications | `testPublishedDirectoryWhoseLeaseWasRemovedIsRetired` | [completed-discovery.patch](completed-discovery.patch) |
| Partial frames cross the old deadline with a controlled clock | `testSlowFragmentedPeerDoesNotBlockAnotherOrLoseItsPartialFrame` | [partial-frame-clock.patch](partial-frame-clock.patch) |
| The independent peer reply has a failure-only bound | `testSlowFragmentedPeerDoesNotBlockAnotherOrLoseItsPartialFrame` | [independent-reply.patch](independent-reply.patch) |
| Stop observes an entered idle reader | `testStoppedServerClosesAnIdlePeerWithoutACommand` | [idle-reader.patch](idle-reader.patch) |
| Replacement waits for actual lease release | `testBrokerLeasePreventsASecondServerUntilOldPeersRetire` | [lease-release.patch](lease-release.patch) |
| Native host exit uses its termination event | `testMalformedNativeLengthFailsInsteadOfBeingRelayed` | [native-process-exit.patch](native-process-exit.patch) |
| Sidecar callbacks observe committed bytes | Generated-silence publication test | [Preserved failure](https://github.com/codemyriad/cassini-mac/blob/d2660d4ab1a289cdbe6fcd9ee3a55171e039cdff/evidence/mac/d88/aws-transport/sidecar-before-write.log) and [patch](https://github.com/codemyriad/cassini-mac/blob/d2660d4ab1a289cdbe6fcd9ee3a55171e039cdff/evidence/mac/d88/aws-transport/sidecar-before-write.patch) |

Mutation failure excerpts are in [mutations.log](mutations.log). Apply a patch with `git apply --unidiff-zero` to reproduce it. Full local logs and the replay configuration are in `~/coordination/evidence/big-mac-d88/areas/transport`.

before — Executed 14 tests, with 0 failures (0 unexpected) in 3.231 (3.234) seconds; ✔ Test run with 0 tests passed after 0.001 seconds.
after — Executed 14 tests, with 0 failures (0 unexpected) in 2.481 (2.483) seconds; ✔ Test run with 0 tests passed after 0.001 seconds.
restored — Executed 14 tests, with 0 failures (0 unexpected) in 2.270 (2.273) seconds; ✔ Test run with 0 tests passed after 0.001 seconds.

The sidecar publication source is byte-identical to the preserved generated-silence proof. Its original mutation is retained. The six transport mutations are rerun on this area tree.
