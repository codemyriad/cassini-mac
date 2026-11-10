The three assigned ControlServiceTests silence assertions previously passed when a real receive deadline expired (or the peer closed). They now inspect ordered output through a heartbeat, or require the fresh profile's first Start to carry the microphone choice set after inventory receipt. Notification count and profile separation checks remain.

Production code is unchanged. Earlier negative receives and other D88 rows remain outside this PR.

Validation: Xcode 16.4, shared heavy lock; unchanged baseline 73 selected tests pass, changed/restored ControlServiceTests 12/12 pass. Mutations for premature first-status reconciliation and forgotten Stop memory both fail the intended assertions. Evidence: `evidence/mac/d88/aws-ipc/`. Source-matched runs stage the changed Swift test into a disposable baseline checkout to reuse its build products.

## Mutation evidence

Baseline 73 selected tests; changed/restored ControlServiceTests 12/12 pass.

- Premature first-status reconciliation fails microphone choice and profile separation. [Patch](https://github.com/codemyriad/cassini-mac/blob/f0b06ccf8ceab27e2d33035a7b27ca5ea3d6fd51/evidence/mac/d88/aws-ipc/premature-start.patch), [failing run](https://github.com/codemyriad/cassini-mac/blob/f0b06ccf8ceab27e2d33035a7b27ca5ea3d6fd51/evidence/mac/d88/aws-ipc/premature-start.log).
- Clearing Stop memory fails the no-restart assertion. [Patch](https://github.com/codemyriad/cassini-mac/blob/f0b06ccf8ceab27e2d33035a7b27ca5ea3d6fd51/evidence/mac/d88/aws-ipc/restart-after-stop.patch), [failing run](https://github.com/codemyriad/cassini-mac/blob/f0b06ccf8ceab27e2d33035a7b27ca5ea3d6fd51/evidence/mac/d88/aws-ipc/restart-after-stop.log).

[Restored passing run](https://github.com/codemyriad/cassini-mac/blob/f0b06ccf8ceab27e2d33035a7b27ca5ea3d6fd51/evidence/mac/d88/aws-ipc/restored.log), [evidence and scope](https://github.com/codemyriad/cassini-mac/blob/f0b06ccf8ceab27e2d33035a7b27ca5ea3d6fd51/evidence/mac/d88/aws-ipc/README.md).

## Shared CI fixture repair

The inherited replacement-lock fixture timed out at ModelSupersessionTests:93 in four CI runs. Its controller and removal task now use a dedicated dispatch-backed task executor; the XCTest wait runs off the cooperative executor. The event still comes from the actual failed flock attempt. Production locking, 5-second lock deadline, 10-second event bound, hash revalidation, cancellation and old-copy assertions are unchanged.

A controlled held-cooperative-worker reproduction fails both original parameter variants at the same event wait; both pass with the fix. Removing replacement hash revalidation still fails the hash-error and old-copy-retention assertions. The restored suite passes. This head also passes its row tests together with all seven ordinary supersession tests under Xcode 16.4 and the shared heavy lock.

[Before reproduction](https://github.com/codemyriad/cassini-mac/blob/9d373ff997c1d8721cae24fa6c805fd0da42662a/evidence/mac/d88/aws-supersession/before-held-pool.log), [fixed reproduction](https://github.com/codemyriad/cassini-mac/blob/9d373ff997c1d8721cae24fa6c805fd0da42662a/evidence/mac/d88/aws-supersession/after-held-pool.log), [mutation patch](https://github.com/codemyriad/cassini-mac/blob/9d373ff997c1d8721cae24fa6c805fd0da42662a/evidence/mac/d88/aws-supersession/skip-revalidation.patch), [failing mutation](https://github.com/codemyriad/cassini-mac/blob/9d373ff997c1d8721cae24fa6c805fd0da42662a/evidence/mac/d88/aws-supersession/skip-revalidation.log), [restored run](https://github.com/codemyriad/cassini-mac/blob/9d373ff997c1d8721cae24fa6c805fd0da42662a/evidence/mac/d88/aws-supersession/restored.log), [this row plus shared suite](https://github.com/codemyriad/cassini-mac/blob/9d373ff997c1d8721cae24fa6c805fd0da42662a/evidence/mac/d88/aws-supersession/row-local.log), [recipe and scope](https://github.com/codemyriad/cassini-mac/blob/9d373ff997c1d8721cae24fa6c805fd0da42662a/evidence/mac/d88/aws-supersession/README.md).

## Checked bug classes

- 15/16 checked for the shared fixture: actual cancellation, replacement revalidation and old-copy retention remain asserted; removing revalidation fails the mutation.

Reviewed [cassini-ux review/BUG-CLASSES.md](https://github.com/codemyriad/cassini-ux/blob/1e8a722060c3f014c67fa4eff13c454307cc31ea/review/BUG-CLASSES.md) (D87):
- 17 checked: event barriers and injected heartbeat clock; no assigned silence-on-deadline pass remains.
- 14/15 checked: only a complete ping establishes the output barrier; EOF and timeout fail it.
- 18 checked: based on main, no stacked draft.
- 19 pending: keep draft until CI is green on this exact head; local checks passed.
- 1–13 not applicable: test-only IPC change, no model/UI/format/storage behavior changes.
