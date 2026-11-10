Setup helpers previously yielded or polled until a wall deadline. They now wait for real retry-sleeper registration, blocked installer entry and observed setup-state publication. Retry values, trigger coalescing, cancellation, off-main installation and manifest checks remain. No production code changes.

WatcherTests.swift:21 was individually reviewed and retained: its deadline returns nil, so it fails unless an actual FSEvent with the expected path arrives.

Validation: Xcode 16.4 under shared heavy lock; baseline/changed/restored 29 XCTest plus 4 Swift Testing installation/watcher tests pass. Dropping the coalesced follow-up fails its entered event and final attempt count. Source-matched run details and earlier corrected compiler diagnostics are retained in `evidence/mac/d88/aws-setup/`.

## Mutation evidence

Baseline/changed/restored 29 XCTest plus 4 installation/watcher Swift Testing tests pass.

- Dropping the coalesced follow-up fails its second-attempt event and final count. [Patch](https://github.com/codemyriad/cassini-mac/blob/3fd8e39175df0fd649cfcbaf7fd8edfbc14a6d42/evidence/mac/d88/aws-setup/drop-coalesced.patch), [failing run](https://github.com/codemyriad/cassini-mac/blob/3fd8e39175df0fd649cfcbaf7fd8edfbc14a6d42/evidence/mac/d88/aws-setup/drop-coalesced.log).

[Restored passing run](https://github.com/codemyriad/cassini-mac/blob/3fd8e39175df0fd649cfcbaf7fd8edfbc14a6d42/evidence/mac/d88/aws-setup/restored.log), [evidence and scope](https://github.com/codemyriad/cassini-mac/blob/3fd8e39175df0fd649cfcbaf7fd8edfbc14a6d42/evidence/mac/d88/aws-setup/README.md).

## Shared CI fixture repair

The inherited replacement-lock fixture timed out at ModelSupersessionTests:93 in four CI runs. Its controller and removal task now use a dedicated dispatch-backed task executor; the XCTest wait runs off the cooperative executor. The event still comes from the actual failed flock attempt. Production locking, 5-second lock deadline, 10-second event bound, hash revalidation, cancellation and old-copy assertions are unchanged.

A controlled held-cooperative-worker reproduction fails both original parameter variants at the same event wait; both pass with the fix. Removing replacement hash revalidation still fails the hash-error and old-copy-retention assertions. The restored suite passes. This head also passes its row tests together with all seven ordinary supersession tests under Xcode 16.4 and the shared heavy lock.

[Before reproduction](https://github.com/codemyriad/cassini-mac/blob/c4f3d1e86d1bc66d2d186c3f740fcaaa14a63b34/evidence/mac/d88/aws-supersession/before-held-pool.log), [fixed reproduction](https://github.com/codemyriad/cassini-mac/blob/c4f3d1e86d1bc66d2d186c3f740fcaaa14a63b34/evidence/mac/d88/aws-supersession/after-held-pool.log), [mutation patch](https://github.com/codemyriad/cassini-mac/blob/c4f3d1e86d1bc66d2d186c3f740fcaaa14a63b34/evidence/mac/d88/aws-supersession/skip-revalidation.patch), [failing mutation](https://github.com/codemyriad/cassini-mac/blob/c4f3d1e86d1bc66d2d186c3f740fcaaa14a63b34/evidence/mac/d88/aws-supersession/skip-revalidation.log), [restored run](https://github.com/codemyriad/cassini-mac/blob/c4f3d1e86d1bc66d2d186c3f740fcaaa14a63b34/evidence/mac/d88/aws-supersession/restored.log), [this row plus shared suite](https://github.com/codemyriad/cassini-mac/blob/c4f3d1e86d1bc66d2d186c3f740fcaaa14a63b34/evidence/mac/d88/aws-supersession/row-local.log), [recipe and scope](https://github.com/codemyriad/cassini-mac/blob/c4f3d1e86d1bc66d2d186c3f740fcaaa14a63b34/evidence/mac/d88/aws-supersession/README.md).

## Rented-Mac routing merge validation

Merged main `b1b031bb0fd5f250aeb305b53b8a24c0280fcd4f` with an ordinary merge commit, without rebasing. Current exact head: `56bbf1e2adb703c94011a9e457ec8445dba44b55`. Affected row tests plus all seven shared supersession tests pass under the shared heavy-run lock, Xcode 16.4 / four jobs. [Merged-head local log](https://github.com/codemyriad/cassini-mac/blob/f3baf1172ebfcb93ecc66322cb4ee2c013718e66/evidence/mac/d88/aws-handoff-2026-11-10/routing-merge-validation/213.log); the log is archived on the handoff branch so preserving evidence does not change the tested PR head. Prior mutation links remain valid evidence for the unchanged row implementation. Full CI on this new head is pending; ARM build jobs now request `cm-mac-m4`.

## Checked bug classes

- 15/16 checked for the shared fixture: actual cancellation, replacement revalidation and old-copy retention remain asserted; removing revalidation fails the mutation.

Reviewed [cassini-ux review/BUG-CLASSES.md](https://github.com/codemyriad/cassini-ux/blob/1e8a722060c3f014c67fa4eff13c454307cc31ea/review/BUG-CLASSES.md) (D87):
- 17 checked: real registration/publication events; watcher guard individually retained as failure-only.
- 2 checked: off-main installer and main-actor progress while installation is held.
- 15 checked: retry cancellation and classified failures remain covered.
- 18 checked: base main, independent of other drafts.
- 19 pending: keep draft until full CI is green on exact merged head `56bbf1e2adb703c94011a9e457ec8445dba44b55`; merged-head local checks passed.
- 1, 3–14 not applicable to this test-only helper change.
