# AWS Mac final STATUS

Recorded at 2026-11-11T00:06:27+00:00. big-mac on the 32 GB Scaleway Mac owns PRs #210–#215, including branch pushes, review follow-up, CI and readiness. This Mac's readiness watcher, periodic checkpoint and scheduled finalizer are stopped. Its watcher had repeatedly moved #214 back to ready after it was made draft. The snapshot below reflects GitHub at handover.

| PR | Branch | AWS commit pushed | GitHub head at handover | PR state | CI rollup |
|---|---|---|---|---|---|
| [#210](https://github.com/codemyriad/cassini-mac/pull/210) | `test/d88-aws-ipc-barriers` | `30fc6f3` | `30fc6f3` | Draft | PENDING |
| [#211](https://github.com/codemyriad/cassini-mac/pull/211) | `test/d88-aws-browser-gates` | `d1ebe14` | `d1ebe14` | Draft | PENDING |
| [#212](https://github.com/codemyriad/cassini-mac/pull/212) | `test/d88-aws-playback-gate` | `8c9c389` | `8c9c389` | merged | SUCCESS |
| [#213](https://github.com/codemyriad/cassini-mac/pull/213) | `test/d88-aws-setup-events` | `56bbf1e` | `56bbf1e` | Draft | PENDING |
| [#214](https://github.com/codemyriad/cassini-mac/pull/214) | `test/d88-aws-model-startup` | `c2777e5` | `3960610` | Draft | Unavailable |
| [#215](https://github.com/codemyriad/cassini-mac/pull/215) | `test/d88-aws-transport-events` | `594bf71` | `594bf71` | Draft | PENDING |


All six implementation branches contain the AWS commits and their before, after and mutation evidence. The newer #214 head contains the AWS commit. The shared supersession proof is on `test/d88-aws-supersession-events` at `6ed212b`. The two-path SwiftPM proof is on `ci/rented-mac-routing-paths` at `452c52f` and landed through #222 and #208. The handoff branch archives local validation logs, CI snapshots and PR body snapshots.

The #215 review fix is pushed at `594bf71`. Suppressing the second peer reply while keeping its connection open failed with a receive timeout after 3.521 seconds. The restored run passed 21 XCTest and seven Swift Testing checks. The patch and logs are under `evidence/mac/d88/aws-transport/` on the PR branch.

big-mac takes the outstanding reviews, fixes and CI from here. GitHub is the source for current PR state after this snapshot. All AWS worktrees were clean before writing this final handoff. The AWS Mac terminates at 09:30 UTC on November 11, 2026.

## Questions

None.
