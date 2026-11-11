# Deterministic EPIPE fixture

Main failure: [#1040 worker job](https://github.com/codemyriad/cassini-mac/actions/runs/42826654800/job/129888410516).
`brokenPipeBecomesAnErrorWithoutASignal` unexpectedly accepted its eight-byte
response. Closing the parent's pipe reader does not prove the last reader is
closed: a concurrently forked child can retain the open-file description until
exec, even with CLOEXEC. The failure log has no descriptor snapshot identifying
which child retained it. A controlled extra reader reproduces the exact failed
assertion; `retained-reader.c` independently demonstrates the kernel behavior.

The replacement error-conversion fixture explicitly shuts down a socket's write
endpoint before calling the real `WhistleIO.write`. That endpoint state cannot
be undone by a retained reader. Both with/without-extra-reader cases require
`write`/`EPIPE` and the kernel F_GETNOSIGPIPE flag. There is no sleep, elapsed-time
assertion, retry, or serialization. The existing child-exit test still covers
EPIPE from a real subprocess input pipe; production code is unchanged.

Validation on main fc2ad76: the old test with a controlled extra reader fails its
original assertion. Both replacement cases pass. Mutating production write to
silently discard EPIPE fails both replacement cases at their behavioral
assertion. After restoring production, all 49 Whistle/model tests pass, including
ModelSupersession and the local HTTP fault suite; worker-event harness tests
also pass. Hashes and representative issues are in results.json. Full logs:
`~/coordination/evidence/mac-flaky/`.

For replay, create a disposable worktree at this PR head, select Xcode 16.4 and
its SDK, set CASSINI_FLAKY_EVIDENCE to an external evidence directory, then run
`~/bin/heavy-run python3 evidence/mac/flaky/closed-output/replay.py`.
The script temporarily substitutes the pinned old fixture plus its controlled
reader, restores it, applies a real production error-handling mutation, and
restores all source in finally. Do not build concurrently in that worktree.
The native probe can also be compiled with the selected SDK's clang.

D87: #17 checked by descriptor state and real behavioral mutation, no timing
success path; #15 checks the exact operation/error; #18 based directly on current
main fc2ad76, no draft dependencies; #19 exact-head CI pending. Other classes
are unaffected by this test-only fixture change.
