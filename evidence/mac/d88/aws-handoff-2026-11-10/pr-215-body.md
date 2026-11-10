Transport tests used sleeps/polling for discovery, partial-frame delay, broker replacement and process exit. They now wait for completed scans, actual lease retirement, reader entry and termination events. The partial-header test holds the real FIFO reader, requires another peer to round-trip, advances a read clock 350 ms across the former 250 ms boundary, then releases the remaining bytes. Production default clocks, polling and discovery scheduling stay unchanged.

The inventory's MeetingTests progress loop now inspects committed sidecar bytes from a synchronous publication callback, then joins the worker via its completion event. Retained-tail, final text/count and completion assertions remain.

Validation: Xcode 16.4 under shared heavy lock. Focused 20 tests pass before/after/restoration. Broad 415 XCTest tests (22 inherited asset skips) plus five Swift Testing cases pass before/after/restoration. Reintroducing the 250 ms deadline fails the fragmented-frame assertions. Evidence: `evidence/mac/d88/aws-transport/`.

Local limitation: the real recognizer resume fixture retains its original asset guard and is skipped locally in baseline and changed runs. Exact-head pipeline CI must exercise it with the pinned assets before readiness. Existing speech-fixture guards remain unchanged. The additional publication test was exercised locally with the pinned VAD cache and generated silence.

Supplemental validation: a generated-silence test reads the actual sidecar from the publication callback. Notifying before atomic write fails the committed-file and publication-count assertions; restoring it passes all 21 focused tests without skips. No production code changed after the earlier broad run. Evidence: `sidecar-after.log`, `sidecar-before-write.patch` / `.log`, and `sidecar-restored.log` in the same evidence directory.

## Mutation evidence

Initial focused 20 and broad 415 XCTest (22 original asset skips) plus 5 Swift Testing pass before/after/restoration. The supplemental generated-silence publication proof and restored 21 focused tests pass without skips; the real speech-resume golden remains for pipeline CI.

- A reintroduced 250 ms deadline fails real fragmented-frame assertions after explicit 350 ms clock advance. [Patch](https://github.com/codemyriad/cassini-mac/blob/8f5cdab91a904d4695b4f0a2b1c4aaa46376ff85/evidence/mac/d88/aws-transport/partial-deadline.patch), [failing run](https://github.com/codemyriad/cassini-mac/blob/8f5cdab91a904d4695b4f0a2b1c4aaa46376ff85/evidence/mac/d88/aws-transport/partial-deadline.log).
- Notifying before atomic write fails actual committed-file and publication-count assertions. [Patch](https://github.com/codemyriad/cassini-mac/blob/8f5cdab91a904d4695b4f0a2b1c4aaa46376ff85/evidence/mac/d88/aws-transport/sidecar-before-write.patch), [failing run](https://github.com/codemyriad/cassini-mac/blob/8f5cdab91a904d4695b4f0a2b1c4aaa46376ff85/evidence/mac/d88/aws-transport/sidecar-before-write.log).

[Restored passing run](https://github.com/codemyriad/cassini-mac/blob/8f5cdab91a904d4695b4f0a2b1c4aaa46376ff85/evidence/mac/d88/aws-transport/restored.log), [evidence and scope](https://github.com/codemyriad/cassini-mac/blob/8f5cdab91a904d4695b4f0a2b1c4aaa46376ff85/evidence/mac/d88/aws-transport/README.md).

[Supplemental restored 21-test run](https://github.com/codemyriad/cassini-mac/blob/8f5cdab91a904d4695b4f0a2b1c4aaa46376ff85/evidence/mac/d88/aws-transport/sidecar-restored.log).

## Shared CI fixture repair

The inherited replacement-lock fixture timed out at ModelSupersessionTests:93 in four CI runs. Its controller and removal task now use a dedicated dispatch-backed task executor; the XCTest wait runs off the cooperative executor. The event still comes from the actual failed flock attempt. Production locking, 5-second lock deadline, 10-second event bound, hash revalidation, cancellation and old-copy assertions are unchanged.

A controlled held-cooperative-worker reproduction fails both original parameter variants at the same event wait; both pass with the fix. Removing replacement hash revalidation still fails the hash-error and old-copy-retention assertions. The restored suite passes. This head also passes its row tests together with all seven ordinary supersession tests under Xcode 16.4 and the shared heavy lock.

[Before reproduction](https://github.com/codemyriad/cassini-mac/blob/2a80631e207765524044523fe0b6a643d7571942/evidence/mac/d88/aws-supersession/before-held-pool.log), [fixed reproduction](https://github.com/codemyriad/cassini-mac/blob/2a80631e207765524044523fe0b6a643d7571942/evidence/mac/d88/aws-supersession/after-held-pool.log), [mutation patch](https://github.com/codemyriad/cassini-mac/blob/2a80631e207765524044523fe0b6a643d7571942/evidence/mac/d88/aws-supersession/skip-revalidation.patch), [failing mutation](https://github.com/codemyriad/cassini-mac/blob/2a80631e207765524044523fe0b6a643d7571942/evidence/mac/d88/aws-supersession/skip-revalidation.log), [restored run](https://github.com/codemyriad/cassini-mac/blob/2a80631e207765524044523fe0b6a643d7571942/evidence/mac/d88/aws-supersession/restored.log), [this row plus shared suite](https://github.com/codemyriad/cassini-mac/blob/2a80631e207765524044523fe0b6a643d7571942/evidence/mac/d88/aws-supersession/row-local.log), [recipe and scope](https://github.com/codemyriad/cassini-mac/blob/2a80631e207765524044523fe0b6a643d7571942/evidence/mac/d88/aws-supersession/README.md).

## Checked bug classes

- 15/16 checked for the shared fixture: actual cancellation, replacement revalidation and old-copy retention remain asserted; removing revalidation fails the mutation.

Reviewed [cassini-ux review/BUG-CLASSES.md](https://github.com/codemyriad/cassini-ux/blob/1e8a722060c3f014c67fa4eff13c454307cc31ea/review/BUG-CLASSES.md) (D87):
- 17 checked: completed scans, read gates, manual clock and exit/write events replace assigned sleeps/polling.
- 14 checked: complete-frame, partial-frame and EOF assertions remain.
- 15 checked: malformed-host exit status and transport-close paths remain.
- 18 checked: base main, independent of the other drafts.
- 19 pending exact-head CI, including the real pipeline fixture. Keep draft.
- 1–13 not applicable: no new transcript ordering, format or storage policy.
