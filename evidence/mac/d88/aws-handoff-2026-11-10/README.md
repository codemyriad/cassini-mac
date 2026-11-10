# AWS Mac handoff — 2026-11-10

**This Mac is destroyed after 2026-11-11 12:09 UTC**, earlier than the original
brief. Move before this deadline. All task source and evidence are on origin;
this branch additionally preserves operational scripts and the status snapshot.
No build products, downloaded assets, credentials or machine lock files are needed.

## Published work

| Row | PR | Branch | Exact tested head |
|---|---|---|---|
| IPC silence | #210 | test/d88-aws-ipc-barriers | f0b06ccf8ceab27e2d33035a7b27ca5ea3d6fd51 |
| Browser broker/start/permissions | #211 | test/d88-aws-browser-gates | 54c574b672ddd10b3ea5cfb9af42fb9d6734dc47 |
| Playback cancellation | #212 | test/d88-aws-playback-gate | ac49a7503d35c32837b2a93605028f6525e6fc95 |
| Setup/watcher | #213 | test/d88-aws-setup-events | 3fd8e39175df0fd649cfcbaf7fd8edfbc14a6d42 |
| Model fixture | #214 | test/d88-aws-model-startup | 21e957a0aaa5e0f8df4aa857344addc94af511eb |
| Transport discovery/process exit | #215 | test/d88-aws-transport-events | e4b8446b9f7101c587b02fc959b0b1ca696eab76 |

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
   gating without any GitHub mutations. It requires the known commit objects in
   the local clone. Only git revision reads are real in these offline checks.
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
