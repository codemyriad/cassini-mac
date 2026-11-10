# AWS Mac status

**Stop using this Mac by 2026-11-11 08:30 UTC. Termination and disk deletion: 2026-11-11 09:30 UTC.**

Updated: 2026-11-10 23:40 UTC

Main #208 (including #222) merged at `b1b031bb0fd5f250aeb305b53b8a24c0280fcd4f`. Per coordinator, all six draft branches now contain an ordinary merge from that main, with no rebase or force-push. All six heads are pushed and their affected-row plus seven shared supersession tests pass locally under the shared heavy-run lock, Xcode16.4/four jobs. PR bodies include new-head validation links and D87 entries. No new source work is planned; continue existing readiness monitoring only.

| PR | Row | Exact head | State |
|---|---|---|---|
| [#210](https://github.com/codemyriad/cassini-mac/pull/210) | IPC silence | `30fc6f3` | Local pass; exact-head CI pending |
| [#211](https://github.com/codemyriad/cassini-mac/pull/211) | Browser broker/start/permissions | `d1ebe14` | Local pass; exact-head CI pending |
| [#212](https://github.com/codemyriad/cassini-mac/pull/212) | Playback cancellation | `8c9c389` | Local pass; exact-head CI pending |
| [#213](https://github.com/codemyriad/cassini-mac/pull/213) | Setup/watchers | `56bbf1e` | Local pass; exact-head CI pending |
| [#214](https://github.com/codemyriad/cassini-mac/pull/214) | Model fixture startup | `c2777e5` | Local pass; exact-head CI pending |
| [#215](https://github.com/codemyriad/cassini-mac/pull/215) | Transport discovery/process exit | `594bf71` | Local pass. Draft for review |

ARM fast path confirmed: #210 run42886823413 requests `cm-mac-m4` for its ARM build; Intel remains `macos-15-intel`. Readiness automation is `aws-mac-d88-ci`, running `~/coordination/AWS-MAC-CI-WATCH.py --watch --mark-ready`. Its map contains the six full new SHAs and checks completed exact-head green workflows/jobs before updating D87 class19 and marking ready. It cannot push, merge or rerun. Per-PR audit records: `~/READY-AWS-MAC-<PR>.json`.

## Evidence

All original row before/after/mutation evidence and the shared ModelSupersessionTests executor fix are on the six branches. Current merged-head local logs are pushed on `test/d88-aws-handoff` under `evidence/mac/d88/aws-handoff-2026-11-10/routing-merge-validation/`; `results.json` records all six exact source heads and passing exits. The shared lock reproduction, retained-old-copy mutation and final fixture proof also remain on `test/d88-aws-supersession-events` at `6ed212bb12abacec8ec1feaca1e30a9282c68fe9`. No agy self-checks.

#222's real two-path SwiftPM proof is merged through #208. Its original pushed branch `ci/rented-mac-routing-paths` at `452c52f66d90fd5d1f987dff90197620554e833e` retains complete Cassini producer/consumer build evidence, three actual path-dependent tests, actual workspace-guard mutation failure, same-path reuse and 41 passing contract checks.

## Migration and resource use

All source/evidence and operational scripts are pushed. The separate `aws-mac-d88-checkpoint` tmux session pushes STATUS, CI observations, scripts and audit records onto `test/d88-aws-handoff` every five minutes. Stop both old tmux sessions before starting replacements on the second Mac. Handoff README contains restoration steps and full new head table. No credentials/build caches need migration.

Heavy runs acquire `mkdir ~/.aws-heavy.lock` and the earlier local flock through `~/coordination/aws-mac-test.py`, releasing only their own directory in cleanup. All six merge validations finished and own locks are released. No new heavy runs are planned. Shared contract files come from cassini-ux main; no shared vectors/strings were edited.

## Questions

None. Await exact-head CI; the watcher keeps failed/pending heads draft and marks green heads ready. No new work on this machine beyond the authorized monitoring/status checkpoints.


## #215 review follow-up

The reader gate and both receives are bounded on pushed head `594bf715de569c46b1237c82d73bbc259eaec3d6`. Suppressing the second peer reply with the connection open fails with a receive timeout in 3.521 seconds. After restoration, 21 XCTest and seven Swift Testing checks passed under the shared lock. Evidence and the mutation patch are on the PR branch and linked in the PR body. The watcher tracks the new head and preserves the draft disposition for #215.

## Old host final handoff

Periodic checkpoint cutoff is 08:15 UTC. The readiness watcher stops at 08:20 UTC, when the finalizer takes a fresh CI snapshot and pushes the final handoff. Finalizer commands end by 08:28 UTC. Stop using the Mac by 08:30 UTC on 2026-11-11. Termination and disk deletion are at 09:30 UTC. The handoff branch contains the restoration instructions, head inventory and retirement plan.

## CI readiness

Last checked: 2026-11-10T23:55:05+00:00

- #210 `30fc6f3`: pending: Whistle bundle / Universal app and sandboxed Whistle helper, UX browser setup / Browser setup (macos-15), UX Library boards / Native spectrogram and profiling; draft.
- #211 `d1ebe14`: pending: UX Library boards / Library boards; draft.
- #212 `8c9c389`: ready; ready.
- #213 `56bbf1e`: pending: CassiniKit tests and conformance, UX Library boards / Native spectrogram and profiling; draft.
- #214 `c2777e5`: ready; ready.
- #215 `594bf71`: pending: build_release / Build Release app and package (universal, Xcode 16.4), CassiniKit tests and conformance, UX window screenshots / Window and board-size screenshots, Whistle bundle / Whistle worker (macos-15-intel), Whistle bundle / Universal app and sandboxed Whistle helper, Package tests (macos-15-intel), UX browser setup / Browser setup (macos-15), UX browser setup / Browser setup (macos-15-intel); draft.
