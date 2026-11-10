Browser broker and input tests previously used 5–50 ms sleeps, delayed replies, and PCM/permission/failure polling to establish progress. They now hold folder creation, native drain and OS permission explicitly and observe the actual registration/completion events before asserting. Per-capture microphone events follow a PCM flush. Small internal observers fence real queued work without choosing outcomes.

Capture identity, frame counts, cancellation, saved-state, source-slot and late duplicate reply assertions remain. All fixture audio is generated; no devices or GUI are used.

Validation: Xcode 16.4 under the shared heavy lock. Unchanged baseline 73 selected tests pass; changed/restored browser suites 61/61 pass. Removing the stale-failure generation guard fails the intended failed-side, stop-count and completed-state assertions. An initial local hook-lifetime failure and its correction are retained in `evidence/mac/d88/aws-browser/`. Source-matched runs stage changed Swift files into a disposable main checkout to reuse build products.

## Mutation evidence

Baseline 73 selected tests; changed/restored browser suites 61/61 pass.

- Removing the generation guard fails failed-side, stop-count and saved-state assertions. [Patch](https://github.com/codemyriad/cassini-mac/blob/54c574b672ddd10b3ea5cfb9af42fb9d6734dc47/evidence/mac/d88/aws-browser/stale-failure.patch), [failing run](https://github.com/codemyriad/cassini-mac/blob/54c574b672ddd10b3ea5cfb9af42fb9d6734dc47/evidence/mac/d88/aws-browser/stale-failure.log).

[Restored passing run](https://github.com/codemyriad/cassini-mac/blob/54c574b672ddd10b3ea5cfb9af42fb9d6734dc47/evidence/mac/d88/aws-browser/restored.log), [evidence and scope](https://github.com/codemyriad/cassini-mac/blob/54c574b672ddd10b3ea5cfb9af42fb9d6734dc47/evidence/mac/d88/aws-browser/README.md).

## Shared CI fixture repair

The inherited replacement-lock fixture timed out at ModelSupersessionTests:93 in four CI runs. Its controller and removal task now use a dedicated dispatch-backed task executor; the XCTest wait runs off the cooperative executor. The event still comes from the actual failed flock attempt. Production locking, 5-second lock deadline, 10-second event bound, hash revalidation, cancellation and old-copy assertions are unchanged.

A controlled held-cooperative-worker reproduction fails both original parameter variants at the same event wait; both pass with the fix. Removing replacement hash revalidation still fails the hash-error and old-copy-retention assertions. The restored suite passes. This head also passes its row tests together with all seven ordinary supersession tests under Xcode 16.4 and the shared heavy lock.

[Before reproduction](https://github.com/codemyriad/cassini-mac/blob/9f892f66edf6cfb5d9698b410e232dff1b15cecf/evidence/mac/d88/aws-supersession/before-held-pool.log), [fixed reproduction](https://github.com/codemyriad/cassini-mac/blob/9f892f66edf6cfb5d9698b410e232dff1b15cecf/evidence/mac/d88/aws-supersession/after-held-pool.log), [mutation patch](https://github.com/codemyriad/cassini-mac/blob/9f892f66edf6cfb5d9698b410e232dff1b15cecf/evidence/mac/d88/aws-supersession/skip-revalidation.patch), [failing mutation](https://github.com/codemyriad/cassini-mac/blob/9f892f66edf6cfb5d9698b410e232dff1b15cecf/evidence/mac/d88/aws-supersession/skip-revalidation.log), [restored run](https://github.com/codemyriad/cassini-mac/blob/9f892f66edf6cfb5d9698b410e232dff1b15cecf/evidence/mac/d88/aws-supersession/restored.log), [this row plus shared suite](https://github.com/codemyriad/cassini-mac/blob/9f892f66edf6cfb5d9698b410e232dff1b15cecf/evidence/mac/d88/aws-supersession/row-local.log), [recipe and scope](https://github.com/codemyriad/cassini-mac/blob/9f892f66edf6cfb5d9698b410e232dff1b15cecf/evidence/mac/d88/aws-supersession/README.md).

## Checked bug classes

- 15/16 checked for the shared fixture: actual cancellation, replacement revalidation and old-copy retention remain asserted; removing revalidation fails the mutation.

Reviewed [cassini-ux review/BUG-CLASSES.md](https://github.com/codemyriad/cassini-ux/blob/1e8a722060c3f014c67fa4eff13c454307cc31ea/review/BUG-CLASSES.md) (D87):
- 17 checked: assigned sleeps/polling/delayed replies replaced by real event gates.
- 14 checked: generated PCM is flushed and native drain is explicitly held through all concurrent callers.
- 15 checked: cancellation, current-side failure, stale errors and final saved state remain covered.
- 18 checked: base main, independent of the IPC draft.
- 19 pending: keep draft until exact-head CI is green; local checks passed.
- 1–13 not applicable: no transcript/UI/format/storage policy changes.
