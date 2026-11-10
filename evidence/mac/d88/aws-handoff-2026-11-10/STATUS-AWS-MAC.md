# AWS Mac status

**Destruction deadline: 2026-11-11 12:09 UTC. Move to the second Mac before this time.**

Updated: 2026-11-10 16:25 UTC

- IPC silence: draft PR https://github.com/codemyriad/cassini-mac/pull/210, branch `test/d88-aws-ipc-barriers`, head `f0b06cc`. Baseline 73 tests pass; changed/restored IPC 12/12 pass. Premature-Start and forgotten-Stop mutations fail intended assertions. Await exact-head CI; not ready. Changes passed; architecture builds pending at 14:54.
- Browser broker/start/permissions: draft PR https://github.com/codemyriad/cassini-mac/pull/211, branch `test/d88-aws-browser-gates`, head `54c574b`. Changed/restored 61/61 pass; stale-generation mutation fails intended assertions. Initial cleanup hook overfulfillment fixed and recorded. Await exact-head CI; not ready. Changes passed; architecture builds pending at 14:54.
- Playback cancellation: draft PR https://github.com/codemyriad/cassini-mac/pull/212, head `ac49a75`. All 33 local tests pass before/after/restoration; removing owner cancel fails intended assertions. CI Kit failed in unrelated ModelSupersessionTests:93 (two replacement-lock observer timeouts); the changed playback test passed. No rerun. Evidence/owner routing in handoff `ci-blocker-212.md`.
- Setup/watchers: draft PR https://github.com/codemyriad/cassini-mac/pull/213, head `3fd8e39`. 29 XCTest + 4 Swift Testing pass before/after/restoration; dropped-coalesced-attempt mutation fails intended assertions. Watcher timeout individually retained as failure-only.
- Model fixture: draft PR https://github.com/codemyriad/cassini-mac/pull/214, head `21e957a`. All 26 tests pass before/after/restoration; false-ready URL mutation fails. Manual expiry follows actual child-stall event; existing readiness/transfer/exit gates preserved.
- Transport discovery/process exit: draft PR https://github.com/codemyriad/cassini-mac/pull/215, head `8f5cdab`. Focused 20 and broad 415 XCTest (22 inherited asset skips) + 5 Swift Testing pass before/after/restoration. Reintroduced 250 ms partial-frame deadline fails after manual 350 ms advance. Added generated-silence committed-write proof: passed locally with pinned VAD; notification-before-write mutation fails, restored 21 focused tests pass without skips. Real speech-resume golden remains for pipeline CI. Readiness for #215 follows #210–#214, per coordinator priority.
- Full local test/build runs now acquire the shared directory lock via `mkdir ~/.aws-heavy.lock` and release it via `rmdir` in cleanup, in addition to the prior local flock. Wrapper: `~/coordination/aws-mac-test.py` (also `/tmp/aws-mac-test.py`), Xcode 16.4, 4 jobs. No Mac heavy run currently active. Shared mkdir lock verified with a lightweight command; existing owners are never removed. Reusing `/tmp/cassini-aws-d88-before-build` when another run is needed.
- Readiness automation: detached tmux session `aws-mac-d88-ci` (restarted with current exact heads), `~/coordination/AWS-MAC-CI-WATCH.py --watch --mark-ready`; log `~/coordination/aws-mac-ci-watch.log`. Polls every 300 s, audits exact head + completed successful first-attempt workflow/jobs before updating own D87 class 19 and marking ready. Seven offline success/rejection-gate checks pass. No push, merge or rerun capability. It continues after this turn; per-PR audit records go to `~/READY-AWS-MAC-<PR>.json`.

## Migration

All six work branches and evidence are pushed. Handoff scripts and a status snapshot are preserved on `test/d88-aws-handoff`; no credentials or build caches are needed for restoration. Checkpoint branch: `test/d88-aws-handoff`, archive `evidence/mac/d88/aws-handoff-2026-11-10/`. A separate `aws-mac-d88-checkpoint` tmux session pushes status, scripts, and readiness audit records there every five minutes. Logs: `~/coordination/aws-mac-checkpoint.log`. Stop both old tmux sessions before resuming on the second Mac.

## Current blocker

#212 Kit failed in existing `ModelSupersessionTests.replacementIsRecheckedAfterItsLockAndCancellationKeepsOld`, line 93, both parameter variants timed out waiting for the real lock observer. Playback cancellation test passed. Investigation/routing recorded in `test/d88-aws-handoff` (`ci-blocker-212.md`); no rerun or deadline inflation. Other PRs still await exact-head CI.

## Questions

Ownership clarification pending: should the existing ModelSupersessionTests CI blocker stay with drmeyers/coordinator, or be assigned to aws-mac? It is outside this brief’s ONLY-listed rows. Other PR readiness continues. All source/evidence is pushed; no merges, reruns or force-pushes performed.

## CI readiness

Last checked: 2026-11-10T16:30:20+00:00

- #210 `f0b06cc`: pending: CassiniKit tests and conformance, Whistle bundle / Whistle worker (macos-15), Whistle bundle / Universal app and sandboxed Whistle helper, UX browser setup / Browser setup (macos-15), UX browser setup / Browser setup (macos-15-intel), UX Library boards / Library boards, UX Library boards / Native spectrogram and profiling, UX Parakeet Ultra / Parakeet runtime, goldens and app (macos-15), UX Parakeet Ultra / Parakeet runtime, goldens and app (macos-15-intel); draft.
- #211 `54c574b`: pending: build_release / Build Release app and package (universal, Xcode 16.4), CassiniKit tests and conformance, UX window screenshots / Window and board-size screenshots, Whistle bundle / Whistle worker (macos-15), Whistle bundle / Whistle worker (macos-15-intel), Whistle bundle / Universal app and sandboxed Whistle helper, Package tests (macos-15-intel), UX browser setup / Browser setup (macos-15), UX browser setup / Browser setup (macos-15-intel); draft.
- #212 `ac49a75`: failed: CassiniKit tests and conformance; draft.
- #213 `3fd8e39`: pending: build_release / Build Release app and package (universal, Xcode 16.4), CassiniKit tests and conformance, UX window screenshots / Window and board-size screenshots, Whistle bundle / Whistle worker (macos-15), Whistle bundle / Whistle worker (macos-15-intel), Whistle bundle / Universal app and sandboxed Whistle helper, Package tests (macos-15-intel), UX browser setup / Browser setup (macos-15), UX browser setup / Browser setup (macos-15-intel); draft.
- #214 `21e957a`: failed: CassiniKit tests and conformance; draft.
- #215 `8f5cdab`: pending: build / Build products (arm64, Xcode 16.4); draft.
