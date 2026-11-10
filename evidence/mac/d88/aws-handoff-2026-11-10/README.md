# AWS Mac handoff — 2026-11-10

**This Mac is destroyed after 2026-11-11 12:09 UTC**, earlier than the original
brief. Move before this deadline. All task source and evidence are on origin;
this branch additionally preserves operational scripts and the status snapshot.
No build products, downloaded assets, credentials or machine lock files are needed.

## Published work

| Row | PR | Branch | Exact tested head |
|---|---|---|---|
| IPC silence | #210 | test/d88-aws-ipc-barriers | 30fc6f3db0ec9be68e2c197e62b69db351ac9a1d |
| Browser broker/start/permissions | #211 | test/d88-aws-browser-gates | d1ebe142862c3a4147866ee6cb0d6cbd229c56b8 |
| Playback cancellation | #212 | test/d88-aws-playback-gate | 8c9c38988c93e2d3e142e2e26dd631287e12b88d |
| Setup/watcher | #213 | test/d88-aws-setup-events | 56bbf1e2adb703c94011a9e457ec8445dba44b55 |
| Model fixture | #214 | test/d88-aws-model-startup | c2777e51e8a48cdb4ae3bd4419d063c2fd67a701 |
| Transport discovery/process exit | #215 | test/d88-aws-transport-events | 612bb36a1df7fd6296cba7061523ba743ffe7817 |

Every branch has before/after and mutation evidence under `evidence/mac/d88/`.
All local final suites pass. Transport retains 22 original asset-dependent skips;
its real recognizer fixture must run in the existing asset-supplied pipeline CI.
All PRs were draft at this snapshot, awaiting their architecture builds. The JSON
snapshot records the exact observation time; consult GitHub for newer results.
No merges, force-pushes or reruns have been performed.

## Restore on the second Mac

1. Fetch all origin branches into the replacement clone. Set `CASSINI_MAC_REPO`
   to that clone's absolute path if it is not `~/agents/cassini-mac`.
2. Copy the status snapshot to `~/STATUS-AWS-MAC.md`, preserving any newer status
   from the first Mac. Place `ci-watch.py` and `test-ready-gates.py` together.
3. Run `python3 test-ready-gates.py`. Seven offline success/rejection cases verify
   gating without any GitHub mutations or network calls. The watcher contains
   the full tested SHAs and needs no local git object lookup to check readiness.
4. Stop the **old** `aws-mac-d88-ci` tmux session before starting a replacement.
   The old host's active script is `~/coordination/AWS-MAC-CI-WATCH.py`; its log is
   `~/coordination/aws-mac-ci-watch.log`. Do not run two readiness writers.
5. On the replacement, `python3 ci-watch.py` performs one read-only audit. Use
   `--watch` for five-minute polling; add `--mark-ready` only to continue the
   already-authorized readiness operation. Run this in a detached tmux session.
   `gh` must be authenticated on the replacement Mac; no auth files are archived.

The watcher is restricted to the six exact heads above. It requires green check
contexts, successful first-attempt completed workflow runs and jobs, then rechecks
the PR head and workflow immediately before updating its own D87 class 19 entry
and marking ready. The model PR additionally requires successful Intel package
tests; transport additionally requires a successful Whistle check. It never pushes,
merges, or reruns jobs. It writes `~/CI-AWS-MAC.json`, updates the CI section of
`~/STATUS-AWS-MAC.md`, and records successful audits as `~/READY-AWS-MAC-<PR>.json`.
A head change, failure, incomplete job or audit error prevents marking ready.

## Shared heavy-run lock

`run-heavy.py COMMAND ...` uses `mkdir ~/.aws-heavy.lock`, waits while another
owner holds it, and uses `rmdir` in cleanup after its child command. It also keeps
the earlier `~/.cassini-heavy.lock` flock. Never delete another owner's directory.
The default developer directory is Xcode 16.4, matching the recorded local runs.
Build/test caches may be recreated rather than transferred.

`aws-d88-verify.py`, `aws-model-verify.py` and `aws-transport-verify.py` are the
historical staging/mutation recipes used on this host. They contain the recorded
host paths and expect a disposable baseline at main `9a22168`; adapt paths before
reuse. Their resulting complete logs and patches are already pushed on the six
work branches, so rerunning them is unnecessary for migration. Run any future
full local suite through the shared mkdir lock.

## Ongoing off-host checkpoints

`checkpoint.py --watch` runs in the separate `aws-mac-d88-checkpoint` tmux session
and checkpoints the latest status, CI observations, readiness audit records and
operational scripts every five minutes onto this handoff branch. It only stages
this archive's named public artifacts. It cannot write another branch or force-push.
Its log is `~/coordination/aws-mac-checkpoint.log`. Stop the old checkpoint session
along with the old CI watcher before moving; resume against a dedicated checkout
of this branch on the second Mac. The checkpoint script falls back to its archived watcher and gate-check scripts when the old `~/coordination` paths do not exist. Copy `run-heavy.py` to the new host as needed; do not copy lock directories. This archival branch has no PR and does not alter
the six tested PR heads.

Transport supplemental proof: generated silence with the pinned VAD cache passed, notification-before-write mutation failed, and all 21 focused tests passed after restoration. Recipe: `aws-sidecar-verify.py`. All six become ready independently as full CI goes green on their exact heads, per the latest coordinator instruction.

Additional coordinator-assigned shared-model blocker: **fixed locally and pushed on all six heads**. The complete controlled proof and diagnostic history is preserved on `test/d88-aws-supersession-events` at `6ed212bb12abacec8ec1feaca1e30a9282c68fe9` (no PR). Both original parameter variants fail the controlled held-cooperative-worker reproduction at the actual lock-event wait; both pass with the dedicated task executor. Seven ordinary supersession tests pass; removing replacement hash revalidation fails hash-error and retained-old-copy assertions; restored eight ordinary/probe tests pass. All six row suites plus the shared suite pass locally under the shared lock. Production behavior and the original 5/10-second bounds are unchanged.

Each PR contains the final proof/recipe in `aws-supersession/` and explicit D87 + mutation links in its body. Body snapshots are preserved here as `pr-210-body.md` through `pr-215-body.md`. `apply-supersession.py` and `refresh-shared-evidence.py` are historical one-shot recipes, not migration startup tasks; the source changes are already pushed.

#208 has not merged as of 17:15 UTC. Its ARM Whistle worker failed during Python setup (`mkdir /Users/runner: Permission denied`), recorded in `routing-208-observation.md`; leave that routing work with its owner. No hosted jobs were rerun. Once it merges, integrate main into each still-draft branch with ordinary merges/pushes, locally validate under the shared lock, update each PR's exact tested head and body evidence, and refresh the readiness watcher's expected head map before restarting it. Never force-push or change a ready head.

## Subsequent #208 blocker 1 assignment

Completed local proof and opened draft PR #222 targeting `ci/rented-mac-routing`, branch `ci/rented-mac-routing-paths`, head `452c52f66d90fd5d1f987dff90197620554e833e`. The base #208 head17162d0 already contains the workspace fence and consumer-local rebuild; the PR adds real two-path compiled proof and a guard-removal mutation. Complete Cassini producer/consumer builds + three path-dependent tests pass with producer unavailable; same-path reuse and all41 contract checks pass. Everything is pushed under `evidence/mac/rented-runner-paths/` on that branch. The readiness watcher still covers only #210–#215. See current STATUS for details.

## #208 merged: current six PR heads

Coordinator authorized ordinary main merges after #208 merged. All six branches contain main `b1b031bb0fd5f250aeb305b53b8a24c0280fcd4f` as their second merge parent, with no rebase or force-push. The published-work table and `routing-heads.json` name the new exact heads. Every affected row plus all seven shared supersession tests passes locally under the shared mkdir lock, Xcode16.4/four jobs; transport uses only generated silence for its supplemental publication check. Logs/results are in `routing-merge-validation/`, with staging recipe `aws-validate-routing-merges.py`. CI readiness is pending on these new heads; the watcher map is updated. Earlier #208 pending/failure observations are historical.
