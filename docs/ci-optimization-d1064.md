# D-1064 CI audit (2026-11-15)

CI builds SwiftPM test bundles once per architecture and universal Debug once.
Consumers verify source/pin/Xcode/workspace identities and use `--skip-build`;
a different checkout path deliberately rebuilds SwiftPM (absolute PCH paths).
Release stays off normal PRs. Do not share DerivedData between workspaces or
restore compiled Swift objects from a different source fingerprint.

## Changes and audit results

- All self-hosted-capable jobs, including GUI and Intel rows, run their shell
  steps under `scripts/ci-heavy.py`. Product extraction/rebuild uses it too.
  It takes the **same blocking flock** as iOS `scripts/test-events.py`, with a
  ten-minute acquisition deadline. On the fleet the shared root is `/Users/m1`
  (including the separate GUI account); elsewhere it is the current home.
  `CASSINI_HEAVY_LOCK` or `CASSINI_HEAVY_LOCK_ROOT` can override this. The GUI
  account may lock the owner's existing 0644 file read-only. Provision that file
  before starting a multi-account host; failure to access it fails the job.
  The wrapper preserves architecture selection, child exit status and the lock
  inode, and terminates its process group before releasing on cancellation.
  Hosted runners pass through. Locking is per shell step, so artifact transfers
  and cache actions do not hold CPU capacity. Time spent waiting counts against
  existing job/step deadlines; genuine host saturation can now fail explicitly
  rather than run overlapping compilers/simulators. Local heavy commands retain
  `scripts/heavy.sh`; CI specifically uses iOS's flock API.
- Register a post action **before cache actions**. After uploads and cache saves,
  self-hosted jobs remove job-owned `build` (including DerivedData) and `.build`.
  Default clean checkout also removes interrupted prior job output at startup.
  Screenshot/profiler temp DerivedData already has startup and `always()` cleanup;
  job-private Python environments live in runner-managed `RUNNER_TEMP`. Hosted
  login-session tests keep disposable Library/user state off persistent runners.
  No cleanup touches another workspace, the user's Library, or shared caches.
- Give `changes` its missing ten-minute timeout; all executable jobs now have
  explicit bounds. Reusable-workflow call jobs inherit the callee's bounds.
  All workflows now use `contents: read` (including standalone boards/screenshots,
  which previously inherited defaults); screenshot diff alone also needs
  `actions: read`. No new permission is requested.
- Remove the obsolete `ux/1a-library-model` push trigger (avoids push plus PR work).
  PR code pushes cancel older runs of the same PR. Keep the existing isolated
  labeled-run groups: cancelling a same-head run can leave cancelled required
  checks in the rollup. Unrelated labels skip the DAG. `full-ci` adds Intel,
  Release and GUI coverage; normal PRs retain four Mac jobs. Main push additionally
  builds Release and publishes board baselines, so a prior normal PR is not
  sufficient evidence to skip it. Nightly/manual runs intentionally cover more
  than normal PRs. No unsafe tree-only success reuse across different test tiers.
- Remove Library/Search and SharedPlacement from the generic unit partition.
  Keep their existing UTC/C-locale and asset-backed runs, respectively. Keep the
  downloader partition isolated and the real bookmark test in a hosted session.
  Partition checks cover all five routes and guard against omissions/overlap.
  Locale strings, tokens/badges, import/FLAC/export and pixel oracles are retained.
  Worker jobs still run their asset-dependent integration suites separately;
  their environment is stronger than the generic unit suite's.
- Remove the two-second crash-report sleep from the standalone Whistle workflow.
  Crash collection remains best effort and cannot prove the OS has finished
  writing a report. No test assertion depends on crash-report arrival.
- Use an absolute workspace path for the CI shell wrapper so nested
  `working-directory` conformance steps resolve it correctly (caught and fixed
  during draft CI; a nested-directory regression now covers this). Normal
  completed commands are not signalled again: Homebrew can leave a protected
  helper in their former process group. Cancellation still tears down the owned
  running group; a regression preserves successful/nonzero normal exit status.
- Settle the native sheet (foreground plus both actions hittable) **before** its
  screenshot, using the existing predicate previously checked only afterward.
  UI relaunches that verify preference persistence/cold routing remain necessary.
  No blanket process reuse across fixtures, languages or themes.
- Audited Swift/UI fixed sleeps: the five-second FSEvents and ten-second banner
  tasks are cancellable *failure deadlines*, not settling sleeps. Background setup
  uses an injected manual clock; timeline fixtures use fixed dates. Keep those
  guards. UI menus/sheets use bounded predicates. No wall-time assertions added.
- Fix measurement accounting: Actions reports requested `cm-mac-m4`/`cm-mac-gui`
  labels, not `macos-*`, for rented jobs; include them in Mac execution totals.
  These totals represent resource use, not a hosted billing statement.

## Local tiers and measurements

Fast infrastructure tier (no native build):

```sh
python3 scripts/test-ci-contract.py
python3 scripts/test-ci-heavy.py
python3 scripts/ci-test-xcode.py
python3 scripts/test-swift-test-runner.py
actionlint .github/workflows/*.yml
```

Behavioral Library tier, after `scripts/heavy.sh swift build --build-tests`:

```sh
TZ=UTC LANG=C scripts/heavy.sh swift test --skip-build \
  --filter 'Library|SearchTests' \
  --skip recordingAccessFollowsRenamedBookmarkAndFailsDuringMovePublication
```

Use CI for asset-backed export/worker goldens, the OS-bookmark test, rendered row
and badge pixels, app sandbox and GUI tests. Use `full-ci` for Intel/Release and
all GUI routes. App behavior/contracts and vendored shared files are unchanged.

Measurements on this Mac (Xcode 27, warm prebuilt test bundles):

| Local work | Before | After |
| --- | --- | --- |
| CI contract checks | 68 tests, 3.83 s | 71 tests, 2.42 s |
| Library/Search coverage | 728 executions across two passes, 16.91 s | 364 executions in one pass, 8.19 s |
| Host lock regressions | absent | 8 event-driven process/cleanup tests |

Library figures reproduce the duplicated partition using two consecutive runs
(8.72 + 8.19 s), not a whole-suite benchmark. Unique coverage stays 364 tests:
15 XCTest + 349 Swift Testing. No throughput/latency assertions use these times.
Actual whole-CI timings and test counts are recorded in the ticket/PR after
Actions completes; runner queuing, cold caches and test tiers affect comparison.
