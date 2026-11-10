Follow-up to #208, which is merged. Based on main (b1b031b merged in). Head 512e842 adds the review fixes listed below.

## Why

Today the hosted `macos-15-intel` jobs waited a long time for a runner: the x86_64 build queued 2 to 82 minutes (median 19), `Package tests` 7 to 100 minutes (median 30), the Intel Whistle worker 3 to 130 minutes (median 13). #208 moves the ARM jobs to the rented M4 Macs. This does the same for the Intel jobs that can run headless.

## What changes

Routed with the same rule as #208 (trusted same-repository pull requests and non-PR events use `vars.CM_MAC_RUNNER`; fork pull requests and an unset variable keep `macos-15-intel`):

- **`Build products (x86_64, Xcode 16.4)`**: cross-compiles on the M4 with `swift build --build-tests --arch x86_64` (same Xcode 16.4, same target triple).
- **`Package tests (macos-15-intel)`** and **`Whistle worker (macos-15-intel)`**: every step runs under `arch -x86_64 /bin/bash --noprofile --norc -eo pipefail`, so `swift test`, the x86_64 test bundles and the x86_64 workers execute through Rosetta 2. On a real Intel runner `arch -x86_64` changes nothing, so the hosted fallback behaves as before.

Supporting changes:

- `CASSINI_CI_ARCH` names the architecture of a job's SwiftPM products. `ci-products.py` used the interpreter's `uname`, which is `arm64` on a rented Mac.
- Packing now reads the Mach-O header of every executable and test bundle and refuses to pack a product of another architecture, or products without a test bundle of the named architecture. The same check runs after a verified archive is extracted. Before, the architecture in the product identity was only the machine's name.
- `scripts/ci-product-arch.sh` (used by the restore action) checks that the machine can execute the named architecture before anything is downloaded. If Rosetta 2 is missing it tries `sudo -n softwareupdate --install-rosetta --agree-to-license` under a host lock (two runners share each Mac) and otherwise fails with a clear message.
- #208's rebuild for a consumer in another workspace now passes `--arch`, so a rented Mac regenerates x86_64 products, not arm64 ones, and checks their architecture afterwards.
- On a rented Mac the Intel Whistle row puts the selected Xcode's universal `python3` first on `PATH`. The worker script compiles a constructor fixture and loads it with its own interpreter; with an arm64-only Python that fixture would be arm64 while the worker under test is x86_64. The job checks `platform.machine()` equals the product architecture.

## Timing

Hosted figures are today's successful jobs (10 to 19 per row) from the Actions API: run time and queue (started minus created). Rented figures are this branch's two real CI runs, 42867855394 and 42881438155 (the routing commit 96915cc).

| Job | Hosted Intel run time (min / median / max) | Hosted queue (min / median / max) | Rented M4, this PR | Rented queue |
|---|---|---|---|---|
| Build products (x86_64) | 2m36 / 5m52 / 9m18 | 1m57 / 18m59 / 82m02 | 0m48 and 0m49 with SwiftPM cache (compile 34 s); 3m25 cold | 2 to 13 s |
| Package tests | 0m58 / 1m50 / 2m51 | 6m39 / 29m36 / 99m46 | 1m05 and 1m21 (45 to 59 s of it restore and x86_64 rebuild) | 1 to 2 s |
| Whistle worker (Intel) | 4m04 / 5m22 / 7m43 | 2m51 / 13m13 / 130m19 | 3m17 on the AWS M4 (strict goldens 2m17); 9m02 on a Scaleway M4 while another agent loaded the machines | 2 s |

Local measurements on the AWS M4 (Xcode 16.4, cold `.build`): cross-build 33 s; the same build with the compiler itself under Rosetta 64 s; downloader tests 7 s; export tests 9 s; Whistle pipeline and strict goldens 2m33; worker JFK golden 10 to 24 s. The first Rosetta use of the Xcode toolchain on a machine costs about 90 s once (translation cache).

On an unloaded M4 the Whistle worker is somewhat faster under Rosetta than on a hosted Intel runner; under load it was slower. The main gain is the queue. Data and scripts are in `evidence/mac/rented-runner-intel/`.

## Are the products equivalent?

Compared the `ci-swiftpm-x86_64` artifact this PR built on a rented Mac with the hosted-Intel artifact of main run 42847539392: the same 12 Mach-O files, every one `x86_64` only, platform macOS, minimum OS 15.0, SDK 15.5, the same ad-hoc signature flags and identifier pattern, and the same 13 resource bundles. No row differs.

The signing-identifier and shipped-byte checks (`check-signing-identifiers.py`, `test-release.py`, `test-dmg-layout.py` and the others in that step) run only in the arm64 row on the universal app. That row and its products are not changed here.

The Intel Whistle report from CI records `architecture: x86_64`, and its JFK transcript is identical to the ARM row's.

## What does not move

- **Intel rows of `UX browser setup` and `UX Parakeet Ultra`** stay on hosted `macos-15-intel`. They launch the signed app and XPC services, and the rented Macs have no login session; #208 keeps the ARM rows of the same jobs hosted for that reason. This is not an Intel limit.
- **A cost of routing the producer:** those two hosted Intel jobs now receive products built in another workspace, so #208's rule makes them compile the SwiftPM products themselves on the hosted Intel runner (in this run the restore and rebuild step of the hosted Intel browser-setup job took 3m31, and the job passed in 9m06, inside today's 7m12 to 10m38 range). They no longer wait for a hosted Intel producer first.
- **Things that need real Intel hardware.** Under Rosetta, `hw.optional.avx1_0`, `avx2_0`, `fma` and `avx512f` all read 0, so ONNX Runtime and the Needle engine take their SSE paths; AVX and AVX2 code paths are not exercised by the routed Whistle worker. Timing and performance on Intel CPUs, Intel graphics and real audio hardware are not covered either (hosted VMs did not cover the last two). The Parakeet goldens still run on real Intel through the hosted `UX Parakeet Ultra` row.
- Rosetta 2 must be installed on every runner that carries the label. It is installed on the AWS and Scaleway Macs now; the job's own install attempt stays as a guard for a new machine.

## Review fixes (512e842)

1. **Timeouts (major):** `UX Parakeet Ultra` goes from 15 to 25 minutes. Its hosted Intel row now compiles SwiftPM itself (about 3.5 minutes) and has taken up to 10 minutes without that. I checked the other hosted Intel consumers: `UX browser setup` had 20 minutes against a measured 11m03 with the rebuild, and goes to 25 as well. `Package tests` (25) and the Whistle worker (20) do not rebuild on the hosted fallback, because the producer is hosted there too.
2. **Shell flags:** the `arch` shells now carry `--noprofile --norc -eo pipefail`.
3. **Architecture check:** 32-bit and big-endian Mach-O magics count as foreign; the check fails when `.build/debug` or a test bundle of the named architecture is missing; it also runs after extraction. One deviation from the review's wording: it requires a test bundle but not an executable, because the two-path fixture package of `scripts/test-ci-product-paths.py` has a library and tests only. Every executable that is present is still checked.
4. **Rosetta install race:** a host lock (`/tmp/cassini-ci-rosetta-install.lock`) serializes the install; a waiting runner re-checks and continues. An abandoned lock ends in the normal clear failure after 10 minutes.

## Validation

- Run 42886796075 on 16adaac (before the review fixes): every self-hosted job green, and on hosted runners kit, window screenshots, `Browser setup (macos-15-intel)` and the Whistle app bundle green; the Release build and `Browser setup (macos-15)` were still queued after 55 minutes when the fix commit replaced the run.
- Head 512e842: run in progress. **Not yet green.** Boards and Parakeet have not run on any head of this branch.
- Earlier runs of the routing commit (42881438155, 42883023952) were also green on every self-hosted job.
- After #208 merged, about a dozen pull-request runs restarted and filled all four `cm-mac-m4` runners; the three routed test jobs of this run waited 22 to 25 minutes for a rented runner. With the Intel jobs routed as well, four runners is the capacity to watch.
- #208's two-path product test (`scripts/test-ci-product-paths.py`) passes locally with this branch's `ci-products.py`.
- `Package tests` built on aws-m4-mac-2 and ran on aws-m4-mac-1, so the cross-workspace rebuild path ran for real.
- 50 CI-contract tests (Python 3.14 and 3.9), 6 Xcode-selector tests, actionlint, `git diff --check`.
- Two earlier runs of this branch failed and led to the current design: `actions/setup-python` cannot install on the rented Macs, and x86_64 products built on one rented Mac could not find their resource bundles on another. Both are #208's review findings; this PR reuses #208's fixes. One arm64 build failed on a dropped libopus download (`RemoteDisconnected`) and passed when re-run once.

## Checked bug classes

Against `~/coordination/BUG-CLASSES.md` (D87).

- **#3 Cache keys:** checked. The SwiftPM cache key already carries architecture, Xcode fingerprint and workspace (#208), so the cross-built x86_64 tree never shares a cache with arm64 or with another checkout path. The product identity now carries the named architecture, and `test_packing_rejects_products_of_another_architecture` covers a name that disagrees with the bytes.
- **#14 Completion:** checked. Digest, retry-once and reject-before-extract behaviour of the restore action is unchanged; the Transport tests still pass.
- **#15 Errors:** checked. A runner that cannot execute the product architecture fails before any download with its own message; a failed Rosetta install is reported, not ignored (`ProductArchitecture` tests, 6 cases, including two runners installing at once and an abandoned lock).
- **#16 Platform:** checked. No global machine state is changed by a job except installing Rosetta 2. Python is linked inside `RUNNER_TEMP`, per job. A rented Mac never extracts products of another workspace (#208) and rebuilds for the job's architecture (`test_relocated_swiftpm_is_not_extracted_and_builds_in_the_consumer`).
- **#17 Wall clock:** checked. No elapsed-time assertions added. The new concurrent-install test is gated on events (it reads the waiting runner's message before letting the fake installer finish). Two job timeouts were raised for the measured extra compile, see above. Note: `scripts/test-whistle-worker.py` has existing fixed timeouts (10 s per subprocess, 3 s orphan deadline); one local run failed while this shared Mac had a load average above 500, and six repeats passed.
- **#18 Stacking:** checked. #208 is merged; this is based on main with main merged in.
- **#19 Ready means green:** not yet. Draft again after review; the run on 512e842 is in progress.
- **#1, #2, #4 to #13:** not applicable. No app, rendering, ordering, search, chip, preview, format or localized-copy change.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
