# Intel CI jobs on the rented Apple Silicon Macs (2026-11-10)

Measurements behind the routing of the x86_64 producer row, `Package tests (macos-15-intel)` and
the Intel Whistle worker to `cm-mac-m4` runners. Taken on the rented AWS Mac mini M4 (macOS 27.0,
Xcode 16.4 16F6) and from the Actions API. That Mac is released on 2026-11-11, so the inputs are
kept here.

## Files

- `hosted-intel-jobs-2026-11-10.json`: every `macos-15-intel` job of the 25 most recent `ci.yml`
  runs at 16:50 UTC. Columns: run id, branch, event, job, conclusion, queue seconds (started minus
  created), run seconds, runner, created.
- `intel-steps.sh`: the steps of the two Intel consumer jobs, run locally with an optional
  `arch -x86_64` prefix and timed.
- `macho-summary.py`: lists what CI can observe about SwiftPM products (names, architectures,
  platform, minimum OS, SDK, signature flags and identifier pattern, resource bundles).
- `macho-hosted-intel-42847539392.json`: its output for the hosted-Intel `ci-swiftpm-x86_64`
  artifact of main run 42847539392.
- `macho-local-cross-c759dbe.json`, `macho-ci-cross-42867855394.json`: its output for the local
  cross-build and for the artifact a rented Mac built in CI. Both equal the hosted file on every
  one of the 12 Mach-O rows and the 13 resource bundles.
- `whistle-intel-rosetta-42867855394.json`: the Intel Whistle worker report from CI on a rented
  Mac (`architecture: x86_64`).

## Results

Hosted `macos-15-intel`, successful jobs of the day (min / median / max):

| Job | n | Run time | Queue |
|---|---|---|---|
| Build products (x86_64) | 19 | 2m36 / 5m52 / 9m18 | 1m57 / 18m59 / 82m02 |
| Package tests | 11 | 0m58 / 1m50 / 2m51 | 6m39 / 29m36 / 99m46 |
| Whistle worker (Intel) | 10 | 4m04 / 5m22 / 7m43 | 2m51 / 13m13 / 130m19 |

Rented M4 runners, real CI of the routing branch:

| Job | Run 42867855394 | Run 42881438155 | Queue |
|---|---|---|---|
| Build products (x86_64) | 0m49, aws-m4-mac-2 | 0m48, aws-m4-mac-1 (compile 34 s) | 2 to 13 s |
| Package tests | 1m21, aws-m4-mac-1 | 1m05, aws-m4-mac-2 (restore and rebuild 45 s) | 1 to 2 s |
| Whistle worker (Intel) | 9m02, scw-m4-mac-1 (goldens 5m26) | 3m17, aws-m4-mac-1 (goldens 2m17) | 2 s |

A first, cold x86_64 build on scw-m4-mac-1 took 3m25 (run 42860712254). The 9m02 worker ran while
another agent loaded the machines.

Local, AWS M4, cold `.build`:

| Step | Seconds |
|---|---|
| `swift build --build-tests --arch x86_64` (native compiler, cross) | 33 |
| the same build with the compiler under Rosetta (`arch -x86_64 swift build --build-tests`) | 64 |
| first Rosetta use of the Xcode 16.4 toolchain (translation cache, once per machine) | 89 |
| ModelDownloaderTests under Rosetta (26 tests) | 7 |
| export suites under Rosetta (87 tests) | 9 |
| Whistle regressions / asset integration | 5 / 10 |
| Whistle pipeline and strict goldens under Rosetta (40 tests) | 153 |
| worker privacy guard and JFK golden, x86_64 interpreter (6 runs) | 12 to 24 |

## What Rosetta does not cover

A translated process reads `hw.optional.avx1_0`, `avx2_0`, `fma` and `avx512f` as 0, so ONNX
Runtime and the Needle engine take their SSE paths. AVX and AVX2 code paths, Intel CPU timing,
Intel graphics and real audio hardware need a real Intel Mac.

## Finding for D88 (not changed by the routing PR)

`scripts/test-whistle-worker.py` uses fixed timeouts: 10 s for each worker subprocess and a 3 s
orphan deadline. One local run failed while the shared Mac had a load average above 500; six
repeats passed.
