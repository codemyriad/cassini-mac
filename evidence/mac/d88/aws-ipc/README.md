# AWS Mac D88 IPC silence row

Base: main `9a22168`. Xcode 16.4 on AWS Mac M4, 2026-11-10.

The three assigned timeout-pass checks in ControlServiceTests are replaced by
ordered output barriers. Stopped and existing profiles negotiate heartbeat-v1;
receipt callbacks fence status reconciliation before advancing the injected clock
10,000 ms and reading every frame through the actual ping. The fresh profile
cannot heartbeat before its first status. Its first Start is instead the barrier:
the microphone choice changes after inventory receipt, so a premature Start is
observably wrong. An additional ping drains later frames for both profiles.

Timeout and EOF throw; neither establishes silence. Production code is unchanged.
Other inventory rows and the earlier negative-receive checks are outside this PR.

## Evidence

- `before.log`: unchanged main, all 73 selected IPC/browser tests pass (including
  all 12 ControlServiceTests).
- `after.log`, `restored.log`: all 12 ControlServiceTests pass.
- `premature-start.patch` / `.log`: applying first-status reconciliation at
  meetings arrival makes the microphone-choice and existing-profile assertions fail.
- `restart-after-stop.patch` / `.log`: clearing attempted/Stop memory at status
  arrival makes the no-restart assertion fail.

Local runs serialize through `~/.cassini-heavy.lock`. The baseline checkout is
`/tmp/cassini-aws-d88-before`, with scratch path `/tmp/cassini-aws-d88-before-build`.
After/mutation runs copy only this branch's changed Swift file into that disposable
checkout, execute `swift test --scratch-path ... --jobs 4 --filter ControlServiceTests`,
and restore the source. This reuses build products while testing the exact changed
source. Only the deliberate mutation runs exit nonzero. Full-package CI remains
the readiness gate on the pushed head.

## Checked bug classes

Reviewed `~/coordination/BUG-CLASSES.md` (D87): class 17 checked with event barriers
and injected heartbeat time; class 14 checked by requiring a complete ping frame;
class 15 checked because timeout/EOF fail the absence proof; class 18 checked
(base main). Class 19 remains pending exact-head CI. Classes 1–13 and 16 are not
applicable to this test-only IPC change.
