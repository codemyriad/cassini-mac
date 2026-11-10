# AWS Mac status

**Destruction deadline: 2026-11-11 12:09 UTC. Move to the second Mac before this time.**

Updated: 2026-11-10 17:59 UTC

- IPC silence: draft PR https://github.com/codemyriad/cassini-mac/pull/210, branch `test/d88-aws-ipc-barriers`, head `9d373ff`. Baseline 73 tests pass; changed/restored IPC 12/12 pass. Premature-Start and forgotten-Stop mutations fail intended assertions. Await exact-head CI; not ready. New-head changes check passed; architecture builds queued/running.
- Browser broker/start/permissions: draft PR https://github.com/codemyriad/cassini-mac/pull/211, branch `test/d88-aws-browser-gates`, head `9f892f6`. Changed/restored 61/61 pass; stale-generation mutation fails intended assertions. Initial cleanup hook overfulfillment fixed and recorded. Await exact-head CI; not ready. New-head changes check passed; architecture builds queued/running.
- Playback cancellation: draft PR https://github.com/codemyriad/cassini-mac/pull/212, head `75ea821`. All 33 local tests pass before/after/restoration; removing owner cancel fails intended assertions. The shared ModelSupersessionTests:93 failure is repaired locally on all six heads; changed playback cancellation and shared fixture tests pass. Await new exact-head CI.
- Setup/watchers: draft PR https://github.com/codemyriad/cassini-mac/pull/213, head `c4f3d1e`. 29 XCTest + 4 Swift Testing pass before/after/restoration; dropped-coalesced-attempt mutation fails intended assertions. Watcher timeout individually retained as failure-only.
- Model fixture: draft PR https://github.com/codemyriad/cassini-mac/pull/214, head `922711b`. All 26 tests pass before/after/restoration; false-ready URL mutation fails. Manual expiry follows actual child-stall event; existing readiness/transfer/exit gates preserved.
- Transport discovery/process exit: draft PR https://github.com/codemyriad/cassini-mac/pull/215, head `2a80631`. Focused 20 and broad 415 XCTest (22 inherited asset skips) + 5 Swift Testing pass before/after/restoration. Reintroduced 250 ms partial-frame deadline fails after manual 350 ms advance. Added generated-silence committed-write proof: passed locally with pinned VAD; notification-before-write mutation fails, restored 21 focused tests pass without skips. Real speech-resume golden remains for pipeline CI. All six may become ready independently when exact-head CI is green.
- Full local test/build runs now acquire the shared directory lock via `mkdir ~/.aws-heavy.lock` and release it via `rmdir` in cleanup, in addition to the prior local flock. Wrapper: `~/coordination/aws-mac-test.py` (also `/tmp/aws-mac-test.py`), Xcode 16.4, 4 jobs. All six new heads passed their affected row tests plus seven ordinary supersession tests under the shared lock; no local heavy run currently active. Shared mkdir lock verified with a lightweight command; existing owners are never removed. Reusing `/tmp/cassini-aws-d88-before-build` when another run is needed.
- Readiness automation: detached tmux session `aws-mac-d88-ci` (restarted with current exact heads), `~/coordination/AWS-MAC-CI-WATCH.py --watch --mark-ready`; log `~/coordination/aws-mac-ci-watch.log`. Polls every 300 s, audits exact head + completed successful first-attempt workflow/jobs before updating own D87 class 19 and marking ready. Seven offline success/rejection-gate checks pass. No push, merge or rerun capability. It continues after this turn; per-PR audit records go to `~/READY-AWS-MAC-<PR>.json`.

## Migration

All six work branches and evidence are pushed. Handoff scripts and a status snapshot are preserved on `test/d88-aws-handoff`; no credentials or build caches are needed for restoration. Checkpoint branch: `test/d88-aws-handoff`, archive `evidence/mac/d88/aws-handoff-2026-11-10/`. A separate `aws-mac-d88-checkpoint` tmux session pushes status, scripts, and readiness audit records there every five minutes. Logs: `~/coordination/aws-mac-checkpoint.log`. Stop both old tmux sessions before resuming on the second Mac.

## Current blocker

The shared ModelSupersessionTests:93 CI blocker is fixed on all six pushed heads. A controlled held-cooperative-worker reproduction failed both original parameter variants; the dedicated fixture executor passes both. Seven ordinary tests pass; removing replacement hash revalidation fails hash-error and old-copy-retention assertions; restored eight ordinary/probe tests pass. Each PR includes linked D87 and mutation evidence. Await exact-head full CI; no hosted reruns, merges or agy self-checks.

## Questions

None. Ownership of the shared blocker was explicitly assigned to aws-mac and the repair is complete locally. Proof/recipe is pushed on `test/d88-aws-supersession-events` and copied into each PR's evidence. #208 remains open at new head `17162d0` (17:28 UTC), owner progressing its routing fix. Previous ARM Whistle failure was Python setup attempting mkdir `/Users/runner` (permission denied), job 129993819438. No edits/reruns/comments by aws-mac; ARM routing awaits its merge. Continue monitoring all six independently. Once #208 merges, integrate main into the still-draft branches with ordinary merge/push, revalidate locally under the shared lock, and refresh exact heads/body links; no hosted reruns.

## CI readiness

Last checked: 2026-11-10T18:03:30+00:00

- #210 `9d373ff`: pending: build_release / Build Release app and package (universal, Xcode 16.4), CassiniKit tests and conformance, UX window screenshots / Window and board-size screenshots, Whistle bundle / Whistle worker (macos-15), Whistle bundle / Universal app and sandboxed Whistle helper, Package tests (macos-15-intel), UX browser setup / Browser setup (macos-15), UX browser setup / Browser setup (macos-15-intel); draft.
- #211 `9f892f6`: pending: build_release / Build Release app and package (universal, Xcode 16.4), CassiniKit tests and conformance, UX window screenshots / Window and board-size screenshots, Whistle bundle / Whistle worker (macos-15), Whistle bundle / Whistle worker (macos-15-intel), Whistle bundle / Universal app and sandboxed Whistle helper, Package tests (macos-15-intel), UX browser setup / Browser setup (macos-15), UX browser setup / Browser setup (macos-15-intel); draft.
- #212 `75ea821`: pending: build / Build products (arm64, Xcode 16.4), build / Build products (x86_64, Xcode 16.4); draft.
- #213 `c4f3d1e`: pending: build_release / Build Release app and package (universal, Xcode 16.4), CassiniKit tests and conformance, UX window screenshots / Window and board-size screenshots, Whistle bundle / Whistle worker (macos-15), Whistle bundle / Whistle worker (macos-15-intel), Whistle bundle / Universal app and sandboxed Whistle helper, UX browser setup / Browser setup (macos-15), UX browser setup / Browser setup (macos-15-intel); draft.
- #214 `922711b`: pending: build_release / Build Release app and package (universal, Xcode 16.4), CassiniKit tests and conformance, UX window screenshots / Window and board-size screenshots, Whistle bundle / Whistle worker (macos-15), Whistle bundle / Whistle worker (macos-15-intel), Whistle bundle / Universal app and sandboxed Whistle helper, Package tests (macos-15-intel), UX browser setup / Browser setup (macos-15), UX browser setup / Browser setup (macos-15-intel); draft.
- #215 `2a80631`: pending: build / Build products (arm64, Xcode 16.4); draft.
