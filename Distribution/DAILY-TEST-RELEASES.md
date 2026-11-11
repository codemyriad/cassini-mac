# Unattended Mac test builds

After this PR is merged, run `python3 scripts/install-daily-test-release.py` on
drmeyers. It installs only main into a private dedicated checkout and starts a
local LaunchAgent. It does not install a GitHub self-hosted signing runner or move
credentials. A loaded agent must finish and be unloaded before reinstalling.

The agent checks for due05:00/11:00/20:00 UTC slots year-round, including
missed wakes, and for successful `Request Mac test release` workflow_dispatch
requests on main. Minute pulses discover requests; each slot/request is consumed
once, without sleep or retry loops. Manual workflow status records a request,
not the result of signing. Results/skips and one-line failures go to
`~/dev/cassini-coordination/NOTIFICATIONS-MAC-TEST-RELEASES.log`; private state,
logs and notarization reports stay under `~/.local/share/cassini-mac-test-releases`.

Only current main with its latest CI green can build or publish. Unchanged main
skips. Build numbers are reserved atomically and include failed attempts/drafts.
Each release has an immutable `vVERSION-beta.N` tag, a nightly title, and merged
PR titles since the prior nightly. Failed uploads remain drafts; nothing is
clobbered, deleted or sent to cassini.talk/Sparkle. Test apps disable public
updates and contain no public feed URL.

Existing local signing/notary credentials are reused. Build and DMG creation take
the shared heavy lock separately (five-minute acquisition bound); network/notary
waits hold no heavy lock. Build admission requires25GiB free, preserving a10GiB
reserve; DMG admission requires13GiB and both reject memory pressure/growing swap.
Outputs stay on drmeyers's internal disk while DrMeyers2 is unavailable. Successful
job outputs are removed after publication; failed job diagnostics are retained.
No installer or signed build has been run as part of the pipeline-only PR.
