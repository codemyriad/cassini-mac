The deliberately stalled model-fixture bootstrap test previously passed after 0.1 seconds of real silence. The child now announces entry into its pre-readiness stall, and that event explicitly expires an injected startup clock. The test requires this expiration, child reaping and folder cleanup. A separate real hang bound only fails missing events.

Normal fixture starts retain their default guard and real clock. Existing ready-URL, child-exit, diagnostic-handler, prefix/transfer, cancellation and atomic install/lock gates remain. Downloader production code is unchanged.

Validation: Xcode 16.4 under shared heavy lock; baseline/changed/restored all 26 ModelDownloaderTests pass. Mutating the child to publish a premature valid-looking URL makes the missing-readiness test fail. Only generated loopback model fixtures are used, with DNS forbidden. Source-matched run details and evidence: `evidence/mac/d88/aws-model/`.

## Mutation evidence

Baseline/changed/restored ModelDownloaderTests 26/26 pass. The exact-head Intel model fixture step also passed; full CI is still required.

- A premature valid-looking ready URL makes the missing-readiness test fail. [Patch](https://github.com/codemyriad/cassini-mac/blob/21e957a0aaa5e0f8df4aa857344addc94af511eb/evidence/mac/d88/aws-model/false-ready.patch), [failing run](https://github.com/codemyriad/cassini-mac/blob/21e957a0aaa5e0f8df4aa857344addc94af511eb/evidence/mac/d88/aws-model/false-ready.log).

[Restored passing run](https://github.com/codemyriad/cassini-mac/blob/21e957a0aaa5e0f8df4aa857344addc94af511eb/evidence/mac/d88/aws-model/restored.log), [evidence and scope](https://github.com/codemyriad/cassini-mac/blob/21e957a0aaa5e0f8df4aa857344addc94af511eb/evidence/mac/d88/aws-model/README.md).

## Shared CI fixture repair

The inherited replacement-lock fixture timed out at ModelSupersessionTests:93 in four CI runs. Its controller and removal task now use a dedicated dispatch-backed task executor; the XCTest wait runs off the cooperative executor. The event still comes from the actual failed flock attempt. Production locking, 5-second lock deadline, 10-second event bound, hash revalidation, cancellation and old-copy assertions are unchanged.

A controlled held-cooperative-worker reproduction fails both original parameter variants at the same event wait; both pass with the fix. Removing replacement hash revalidation still fails the hash-error and old-copy-retention assertions. The restored suite passes. This head also passes its row tests together with all seven ordinary supersession tests under Xcode 16.4 and the shared heavy lock.

[Before reproduction](https://github.com/codemyriad/cassini-mac/blob/922711bcbde0531c834f18bccf8a2f2407462923/evidence/mac/d88/aws-supersession/before-held-pool.log), [fixed reproduction](https://github.com/codemyriad/cassini-mac/blob/922711bcbde0531c834f18bccf8a2f2407462923/evidence/mac/d88/aws-supersession/after-held-pool.log), [mutation patch](https://github.com/codemyriad/cassini-mac/blob/922711bcbde0531c834f18bccf8a2f2407462923/evidence/mac/d88/aws-supersession/skip-revalidation.patch), [failing mutation](https://github.com/codemyriad/cassini-mac/blob/922711bcbde0531c834f18bccf8a2f2407462923/evidence/mac/d88/aws-supersession/skip-revalidation.log), [restored run](https://github.com/codemyriad/cassini-mac/blob/922711bcbde0531c834f18bccf8a2f2407462923/evidence/mac/d88/aws-supersession/restored.log), [this row plus shared suite](https://github.com/codemyriad/cassini-mac/blob/922711bcbde0531c834f18bccf8a2f2407462923/evidence/mac/d88/aws-supersession/row-local.log), [recipe and scope](https://github.com/codemyriad/cassini-mac/blob/922711bcbde0531c834f18bccf8a2f2407462923/evidence/mac/d88/aws-supersession/README.md).

## Checked bug classes

- 15/16 checked for the shared fixture: actual cancellation, replacement revalidation and old-copy retention remain asserted; removing revalidation fails the mutation.

Reviewed [cassini-ux review/BUG-CLASSES.md](https://github.com/codemyriad/cassini-ux/blob/1e8a722060c3f014c67fa4eff13c454307cc31ea/review/BUG-CLASSES.md) (D87):
- 17 checked: child event and manual startup clock replace real elapsed silence.
- 14 checked: complete-byte and prefix assertions remain.
- 15 checked: cancellation, bootstrap errors and cleanup remain covered.
- 16 checked: existing atomic install/lock tests remain.
- 18 checked: base main, independent of other drafts.
- 19 pending exact-head CI; keep draft. Local checks passed.
- 1–13 not applicable to this fixture-only change.
