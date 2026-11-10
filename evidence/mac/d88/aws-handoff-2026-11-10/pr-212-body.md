The abandoned playback preparation fixture used a 60-second cancellable sleep without proving its builder had entered. It now waits for an explicit preparation gate, drops the owner, requires cancellation delivery while preparation is held, then releases and joins the task. Weak-owner, task-cancelled and no-play assertions remain. Production code is unchanged.

Validation: Xcode 16.4 under shared heavy lock, baseline/changed/restored 33 SessionPlaybackTests pass. Removing owner cancellation fails both task-cancelled and cancellation-event assertions. Source-matched baseline-checkout runs and mutation evidence are in `evidence/mac/d88/aws-playback/`.

## Mutation evidence

Baseline/changed/restored SessionPlaybackTests 33/33 pass. Its changed cancellation test also passed in CI; the shared ModelSupersessionTests blocker is repaired on this head as described below.

- Removing owner cancellation fails task-cancelled and cancellation-delivery assertions. [Patch](https://github.com/codemyriad/cassini-mac/blob/ac49a7503d35c32837b2a93605028f6525e6fc95/evidence/mac/d88/aws-playback/owner-cancel.patch), [failing run](https://github.com/codemyriad/cassini-mac/blob/ac49a7503d35c32837b2a93605028f6525e6fc95/evidence/mac/d88/aws-playback/owner-cancel.log).

[Restored passing run](https://github.com/codemyriad/cassini-mac/blob/ac49a7503d35c32837b2a93605028f6525e6fc95/evidence/mac/d88/aws-playback/restored.log), [evidence and scope](https://github.com/codemyriad/cassini-mac/blob/ac49a7503d35c32837b2a93605028f6525e6fc95/evidence/mac/d88/aws-playback/README.md).

## Shared CI fixture repair

The inherited replacement-lock fixture timed out at ModelSupersessionTests:93 in four CI runs. Its controller and removal task now use a dedicated dispatch-backed task executor; the XCTest wait runs off the cooperative executor. The event still comes from the actual failed flock attempt. Production locking, 5-second lock deadline, 10-second event bound, hash revalidation, cancellation and old-copy assertions are unchanged.

A controlled held-cooperative-worker reproduction fails both original parameter variants at the same event wait; both pass with the fix. Removing replacement hash revalidation still fails the hash-error and old-copy-retention assertions. The restored suite passes. This head also passes its row tests together with all seven ordinary supersession tests under Xcode 16.4 and the shared heavy lock.

[Before reproduction](https://github.com/codemyriad/cassini-mac/blob/75ea82166b79dcdfc7ad084d5eb30dc71a274a11/evidence/mac/d88/aws-supersession/before-held-pool.log), [fixed reproduction](https://github.com/codemyriad/cassini-mac/blob/75ea82166b79dcdfc7ad084d5eb30dc71a274a11/evidence/mac/d88/aws-supersession/after-held-pool.log), [mutation patch](https://github.com/codemyriad/cassini-mac/blob/75ea82166b79dcdfc7ad084d5eb30dc71a274a11/evidence/mac/d88/aws-supersession/skip-revalidation.patch), [failing mutation](https://github.com/codemyriad/cassini-mac/blob/75ea82166b79dcdfc7ad084d5eb30dc71a274a11/evidence/mac/d88/aws-supersession/skip-revalidation.log), [restored run](https://github.com/codemyriad/cassini-mac/blob/75ea82166b79dcdfc7ad084d5eb30dc71a274a11/evidence/mac/d88/aws-supersession/restored.log), [this row plus shared suite](https://github.com/codemyriad/cassini-mac/blob/75ea82166b79dcdfc7ad084d5eb30dc71a274a11/evidence/mac/d88/aws-supersession/row-local.log), [recipe and scope](https://github.com/codemyriad/cassini-mac/blob/75ea82166b79dcdfc7ad084d5eb30dc71a274a11/evidence/mac/d88/aws-supersession/README.md).

## Rented-Mac routing merge validation

Merged main `b1b031bb0fd5f250aeb305b53b8a24c0280fcd4f` with an ordinary merge commit, without rebasing. Current exact head: `8c9c38988c93e2d3e142e2e26dd631287e12b88d`. Affected row tests plus all seven shared supersession tests pass under the shared heavy-run lock, Xcode 16.4 / four jobs. [Merged-head local log](https://github.com/codemyriad/cassini-mac/blob/f3baf1172ebfcb93ecc66322cb4ee2c013718e66/evidence/mac/d88/aws-handoff-2026-11-10/routing-merge-validation/212.log); the log is archived on the handoff branch so preserving evidence does not change the tested PR head. Prior mutation links remain valid evidence for the unchanged row implementation. Full CI on this new head is pending; ARM build jobs now request `cm-mac-m4`.

## Checked bug classes

- 15/16 checked for the shared fixture: actual cancellation, replacement revalidation and old-copy retention remain asserted; removing revalidation fails the mutation.

Reviewed [cassini-ux review/BUG-CLASSES.md](https://github.com/codemyriad/cassini-ux/blob/1e8a722060c3f014c67fa4eff13c454307cc31ea/review/BUG-CLASSES.md) (D87):
- 17 checked: entered/cancel/release gates replace the fixed sleep; deadlines only fail missing events.
- 15 checked: actual cancellation delivery and no transport playback remain asserted.
- 18 checked: base main, independent of other drafts.
- 19 pending: keep draft until full CI is green on exact merged head `8c9c38988c93e2d3e142e2e26dd631287e12b88d`; merged-head local checks passed.
- 1–14 not applicable to this test-only fixture.
