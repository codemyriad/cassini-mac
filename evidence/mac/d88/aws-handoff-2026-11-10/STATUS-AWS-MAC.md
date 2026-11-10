# AWS Mac status

**Destruction deadline: 2026-11-11 12:09 UTC. Move to the second Mac before this time.**

Updated: 2026-11-10 15:29 UTC

- IPC silence: draft PR https://github.com/codemyriad/cassini-mac/pull/210, branch `test/d88-aws-ipc-barriers`, head `f0b06cc`. Baseline 73 tests pass; changed/restored IPC 12/12 pass. Premature-Start and forgotten-Stop mutations fail intended assertions. Await exact-head CI; not ready. Changes passed; architecture builds pending at 14:54.
- Browser broker/start/permissions: draft PR https://github.com/codemyriad/cassini-mac/pull/211, branch `test/d88-aws-browser-gates`, head `54c574b`. Changed/restored 61/61 pass; stale-generation mutation fails intended assertions. Initial cleanup hook overfulfillment fixed and recorded. Await exact-head CI; not ready. Changes passed; architecture builds pending at 14:54.
- Playback cancellation: draft PR https://github.com/codemyriad/cassini-mac/pull/212, head `ac49a75`. All 33 tests pass before/after/restoration; removing owner cancel fails intended assertions.
- Setup/watchers: draft PR https://github.com/codemyriad/cassini-mac/pull/213, head `3fd8e39`. 29 XCTest + 4 Swift Testing pass before/after/restoration; dropped-coalesced-attempt mutation fails intended assertions. Watcher timeout individually retained as failure-only.
- Model fixture: draft PR https://github.com/codemyriad/cassini-mac/pull/214, head `21e957a`. All 26 tests pass before/after/restoration; false-ready URL mutation fails. Manual expiry follows actual child-stall event; existing readiness/transfer/exit gates preserved.
- Transport discovery/process exit: draft PR https://github.com/codemyriad/cassini-mac/pull/215, head `8f5cdab`. Focused 20 and broad 415 XCTest (22 inherited asset skips) + 5 Swift Testing pass before/after/restoration. Reintroduced 250 ms partial-frame deadline fails after manual 350 ms advance. Added generated-silence committed-write proof: passed locally with pinned VAD; notification-before-write mutation fails, restored 21 focused tests pass without skips. Real speech-resume golden remains for pipeline CI. Readiness for #215 follows #210–#214, per coordinator priority.
- Full local test/build runs now acquire the shared directory lock via `mkdir ~/.aws-heavy.lock` and release it via `rmdir` in cleanup, in addition to the prior local flock. Wrapper: `~/coordination/aws-mac-test.py` (also `/tmp/aws-mac-test.py`), Xcode 16.4, 4 jobs. No Mac heavy run currently active. Shared mkdir lock verified with a lightweight command; existing owners are never removed. Reusing `/tmp/cassini-aws-d88-before-build` when another run is needed.
- Readiness automation: detached tmux session `aws-mac-d88-ci` (restarted with current exact heads), `~/coordination/AWS-MAC-CI-WATCH.py --watch --mark-ready`; log `~/coordination/aws-mac-ci-watch.log`. Polls every 300 s, audits exact head + completed successful first-attempt workflow/jobs before updating own D87 class 19 and marking ready. Seven offline success/rejection-gate checks pass. No push, merge or rerun capability. It continues after this turn; per-PR audit records go to `~/READY-AWS-MAC-<PR>.json`.

## Migration

All six work branches and evidence are pushed. Handoff scripts and a status snapshot are preserved on `test/d88-aws-handoff`; no credentials or build caches are needed for restoration. Checkpoint branch: `test/d88-aws-handoff`, archive `evidence/mac/d88/aws-handoff-2026-11-10/`. A separate `aws-mac-d88-checkpoint` tmux session pushes status, scripts, and readiness audit records there every five minutes. Logs: `~/coordination/aws-mac-checkpoint.log`. Stop both old tmux sessions before resuming on the second Mac.

## Questions

None. All six assigned rows are pushed; exact-head CI is the remaining gate. No merges, reruns or force-pushes performed.

## CI readiness

Last checked: 2026-11-10T15:29:52+00:00

- #210 `f0b06cc`: pending: build / Build products (arm64, Xcode 16.4); draft.
- #211 `54c574b`: pending: build / Build products (arm64, Xcode 16.4), build / Build products (x86_64, Xcode 16.4); draft.
- #212 `ac49a75`: pending: build / Build products (arm64, Xcode 16.4), build / Build products (x86_64, Xcode 16.4); draft.
- #213 `3fd8e39`: pending: build / Build products (arm64, Xcode 16.4), build / Build products (x86_64, Xcode 16.4); draft.
- #214 `21e957a`: pending: build / Build products (x86_64, Xcode 16.4); draft.
- #215 `8f5cdab`: pending: changes; draft.
