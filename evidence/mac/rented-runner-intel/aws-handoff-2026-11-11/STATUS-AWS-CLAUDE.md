# STATUS aws-claude: final handoff

Written: 2026-11-10 21:45 UTC on the rented AWS Mac (terminated 2026-11-11 09:30 UTC, disk deleted).
This file is also pushed: branch `ci/rented-mac-intel-handoff` of codemyriad/cassini-mac,
`evidence/mac/rented-runner-intel/aws-handoff-2026-11-11/STATUS-AWS-CLAUDE.md`.

## Result
Feasible and implemented. The x86_64 SwiftPM products cross-compile on the rented M4 Macs and the Intel
test jobs pass under Rosetta 2, with seconds of queue when a rented runner is free.

## What is pushed
- **PR #217** (draft): https://github.com/codemyriad/cassini-mac/pull/217, base `main`, branch `ci/rented-mac-intel-routing`, head **512e842**.
  - 96915cc routing: x86_64 producer row, `Package tests (macos-15-intel)`, Intel Whistle worker go to `vars.CM_MAC_RUNNER` (same fork guard as #208, `macos-15-intel` fallback).
  - 2a3d511 evidence: `evidence/mac/rented-runner-intel/` (timings, Mach-O comparison, scripts, README).
  - 16adaac merge of main after #208 merged.
  - 512e842 review fixes (agy "fix first"): Parakeet timeout 15 -> 25 and browser-setup 20 -> 25; `--noprofile --norc -eo pipefail` on the arch shells; stricter Mach-O check; host lock around the Rosetta install.
- The PR body holds the timing table, the equivalence check, what cannot move, the review fixes and "Checked bug classes".
- **Handoff branch** `ci/rented-mac-intel-handoff`: this file and a copy of the PR body. No pull request; nothing to merge.
- Nothing of value exists only on this Mac. Local clone: ~/agents/claude-mac (clean, equal to origin).

## State of CI on the head 512e842 (run 42898914490)
- Green on self-hosted `cm-mac-m4` runners: Build products x86_64 (51 s) and arm64 (6m07), Package tests (macos-15-intel) (1m01), Whistle worker (macos-15-intel) (3m10), Whistle worker (macos-15) (6m05).
- Still queued for GitHub-hosted runners at 21:42 UTC (since 20:56): kit, Release build, window screenshots, Browser setup (macos-15 and macos-15-intel), Whistle app bundle. Boards and Parakeet start after the Release build.
- **The head is not fully green and the PR is draft.**
- On earlier heads of the same change these hosted jobs passed: kit, window screenshots, both browser-setup rows, Release build, Whistle app bundle. **Boards and Parakeet have never run on this branch.**

## What remains (for whoever continues; no Mac needed)
1. Watch run 42898914490: `gh run view 42898914490 -R codemyriad/cassini-mac`.
2. When every job is green on 512e842: `gh pr ready 217 -R codemyriad/cassini-mac`. Update the "Validation" and "#19" lines of the PR body first (they say "run in progress / not yet").
3. If the hosted **Parakeet Intel** row fails or times out: it is the job behind the major review item. It now compiles SwiftPM itself (about 3.5 min, workspace fence) and has a 25 min limit. Look at the duration of its `ci-products` step.
4. If main moves and conflicts: merge main in (no force-push). Conflict-prone files: `scripts/ci-products.py`, `scripts/test-ci-contract.py`, `.github/workflows/ux-whistle.yml`, `.github/actions/ci-products/action.yml`.
5. One open point for the reviewer: the Mach-O check requires a test bundle of the named architecture but not an executable (review asked for both), because the two-path fixture of `scripts/test-ci-product-paths.py` has a library and tests only. Present executables are still checked.

## Measurements (details in evidence/mac/rented-runner-intel/README.md)
| Job | Rented M4 | Rented queue (runner free) | Hosted Intel 2026-11-10, run median / queue median |
|---|---|---|---|
| Build products (x86_64) | 15-51 s with cache; 3m25 cold | 2-13 s | 5m52 / 18m59 |
| Package tests | 1m01 to 2m41 | 1-2 s | 1m50 / 29m36 |
| Whistle worker (Intel) | 2m46 to 4m42; 9m02 once under another agent's load | 2 s | 5m22 / 13m13 |
- Cross-built x86_64 artifact equals the hosted-Intel one on all 12 Mach-Os (arch, minos 15.0, sdk 15.5, signature flags) and 13 resource bundles.
- Signing-identifier and shipped-byte checks run only in the arm64 row on the universal app; not changed.

## What stays hosted / needs real Intel
- Intel rows of `UX browser setup` and `UX Parakeet Ultra` stay on `macos-15-intel` (app and XPC need a login session). They rebuild SwiftPM on the hosted runner when the producer was a rented Mac.
- Under Rosetta `hw.optional.avx1_0/avx2_0/fma/avx512f` read 0: AVX/AVX2 paths of ONNX Runtime and Needle are not exercised by the routed Whistle worker. Parakeet goldens still run on real Intel (hosted row). Intel timing, Intel graphics and real audio hardware need a real Intel Mac.

## Findings for others
- **Runner capacity:** after #208 merged, about 12 PR runs restarted and filled all 4 `cm-mac-m4` runners; my routed test jobs waited 22-25 min for a rented runner. When the AWS Mac goes away only the 2 Scaleway runners remain for ARM and Intel jobs together. Unsetting `CM_MAC_RUNNER` returns every job to hosted runners.
- **Rosetta on a new runner host:** needed for the Intel jobs. The job installs it only where `sudo -n` works; otherwise it fails with a clear message. Installed on the AWS Mac (by me) and on the Scaleway host (by the coordinator).
- **D88, for the Mac agent:** `scripts/test-whistle-worker.py` has fixed timeouts (10 s per worker subprocess, 3 s orphan deadline). One local run failed at load average >500; six repeats passed. Not changed in #217.
- `scripts/fetch-opus.py` has no retry: one arm64 build failed on `RemoteDisconnected` (libopus download) and passed on one re-run.

## Changes I made to this Mac (all lost with it, none needed elsewhere)
Rosetta 2, `brew install actionlint`, clone at ~/agents/claude-mac. `~/.aws-heavy.lock` is released. No signing keys, no Apple ID, no real recordings were used.

## Questions
None open.
