# AWS Mac status

**Destruction deadline: 2026-11-11 12:09 UTC. Move before this time.**

Updated: 2026-11-10 19:40 UTC

Main #208 (including #222) merged at `b1b031bb0fd5f250aeb305b53b8a24c0280fcd4f`. Per coordinator, all six draft branches now contain an ordinary merge from that main, with no rebase or force-push. All six heads are pushed and their affected-row plus seven shared supersession tests pass locally under the shared heavy-run lock, Xcode16.4/four jobs. PR bodies include new-head validation links and D87 entries. No new source work is planned; continue existing readiness monitoring only.

| PR | Row | Exact head | State |
|---|---|---|---|
| [#210](https://github.com/codemyriad/cassini-mac/pull/210) | IPC silence | `30fc6f3` | Local pass; exact-head CI pending |
| [#211](https://github.com/codemyriad/cassini-mac/pull/211) | Browser broker/start/permissions | `d1ebe14` | Local pass; exact-head CI pending |
| [#212](https://github.com/codemyriad/cassini-mac/pull/212) | Playback cancellation | `8c9c389` | Local pass; exact-head CI pending |
| [#213](https://github.com/codemyriad/cassini-mac/pull/213) | Setup/watchers | `56bbf1e` | Local pass; exact-head CI pending |
| [#214](https://github.com/codemyriad/cassini-mac/pull/214) | Model fixture startup | `c2777e5` | Local pass; exact-head CI pending |
| [#215](https://github.com/codemyriad/cassini-mac/pull/215) | Transport discovery/process exit | `612bb36` | Local pass; exact-head CI pending |

ARM fast path confirmed: #210 run42886823413 requests `cm-mac-m4` for its ARM build; Intel remains `macos-15-intel`. Readiness automation is `aws-mac-d88-ci`, running `~/coordination/AWS-MAC-CI-WATCH.py --watch --mark-ready`. Its map contains the six full new SHAs and checks completed exact-head green workflows/jobs before updating D87 class19 and marking ready. It cannot push, merge or rerun. Per-PR audit records: `~/READY-AWS-MAC-<PR>.json`.

## Evidence

All original row before/after/mutation evidence and the shared ModelSupersessionTests executor fix are on the six branches. Current merged-head local logs are pushed on `test/d88-aws-handoff` under `evidence/mac/d88/aws-handoff-2026-11-10/routing-merge-validation/`; `results.json` records all six exact source heads and passing exits. The shared lock reproduction, retained-old-copy mutation and final fixture proof also remain on `test/d88-aws-supersession-events` at `6ed212bb12abacec8ec1feaca1e30a9282c68fe9`. No agy self-checks.

#222's real two-path SwiftPM proof is merged through #208. Its original pushed branch `ci/rented-mac-routing-paths` at `452c52f66d90fd5d1f987dff90197620554e833e` retains complete Cassini producer/consumer build evidence, three actual path-dependent tests, actual workspace-guard mutation failure, same-path reuse and 41 passing contract checks.

## Migration and resource use

All source/evidence and operational scripts are pushed. The separate `aws-mac-d88-checkpoint` tmux session pushes STATUS, CI observations, scripts and audit records onto `test/d88-aws-handoff` every five minutes. Stop both old tmux sessions before starting replacements on the second Mac. Handoff README contains restoration steps and full new head table. No credentials/build caches need migration.

Heavy runs acquire `mkdir ~/.aws-heavy.lock` and the earlier local flock through `~/coordination/aws-mac-test.py`, releasing only their own directory in cleanup. All six merge validations finished and own locks are released. No new heavy runs are planned. Shared contract files come from cassini-ux main; no shared vectors/strings were edited.

## Questions

None. Await exact-head CI; the watcher keeps failed/pending heads draft and marks green heads ready. No new work on this machine beyond the authorized monitoring/status checkpoints.

## CI readiness

Last checked: 2026-11-10T20:45:22+00:00

- #210 `30fc6f3`: pending: build_release / Build Release app and package (universal, Xcode 16.4), CassiniKit tests and conformance, UX window screenshots / Window and board-size screenshots, Whistle bundle / Whistle worker (macos-15-intel), Whistle bundle / Universal app and sandboxed Whistle helper, UX browser setup / Browser setup (macos-15); draft.
- #211 `d1ebe14`: pending: CassiniKit tests and conformance, Whistle bundle / Whistle worker (macos-15-intel), Package tests (macos-15-intel), UX browser setup / Browser setup (macos-15), UX browser setup / Browser setup (macos-15-intel), UX Library boards / Library boards, UX Library boards / Native spectrogram and profiling, UX Parakeet Ultra / Parakeet runtime, goldens and app (macos-15); draft.
- #212 `8c9c389`: pending: UX window screenshots / Window and board-size screenshots, Whistle bundle / Whistle worker (macos-15-intel), UX browser setup / Browser setup (macos-15), UX browser setup / Browser setup (macos-15-intel), UX Library boards / Library boards, UX Library boards / Native spectrogram and profiling, UX Parakeet Ultra / Parakeet runtime, goldens and app (macos-15), UX Parakeet Ultra / Parakeet runtime, goldens and app (macos-15-intel); draft.
- #213 `56bbf1e`: pending: CassiniKit tests and conformance, UX window screenshots / Window and board-size screenshots, Whistle bundle / Whistle worker (macos-15-intel), Whistle bundle / Universal app and sandboxed Whistle helper, Package tests (macos-15-intel), UX browser setup / Browser setup (macos-15), UX browser setup / Browser setup (macos-15-intel), UX Library boards / Library boards, UX Library boards / Native spectrogram and profiling, UX Parakeet Ultra / Parakeet runtime, goldens and app (macos-15), UX Parakeet Ultra / Parakeet runtime, goldens and app (macos-15-intel); draft.
- #214 `c2777e5`: pending: Whistle bundle / Whistle worker (macos-15-intel), Package tests (macos-15-intel), UX browser setup / Browser setup (macos-15), UX Library boards / Library boards, UX Library boards / Native spectrogram and profiling, UX Parakeet Ultra / Parakeet runtime, goldens and app (macos-15), UX Parakeet Ultra / Parakeet runtime, goldens and app (macos-15-intel); draft.
- #215 `612bb36`: pending: build_release / Build Release app and package (universal, Xcode 16.4), UX window screenshots / Window and board-size screenshots, Package tests (macos-15-intel), UX browser setup / Browser setup (macos-15), UX browser setup / Browser setup (macos-15-intel); draft.
