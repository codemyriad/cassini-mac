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

## Checked bug classes

- 15/16 checked for the shared fixture: actual cancellation, replacement revalidation and old-copy retention remain asserted; removing revalidation fails the mutation.

Reviewed [cassini-ux review/BUG-CLASSES.md](https://github.com/codemyriad/cassini-ux/blob/1e8a722060c3f014c67fa4eff13c454307cc31ea/review/BUG-CLASSES.md) (D87):
- 17 checked: real registration/publication events; watcher guard individually retained as failure-only.
- 2 checked: off-main installer and main-actor progress while installation is held.
- 15 checked: retry cancellation and classified failures remain covered.
- 18 checked: base main, independent of other drafts.
- 19 pending exact-head CI; keep draft. Local checks passed.
- 1, 3–14 not applicable to this test-only helper change.
