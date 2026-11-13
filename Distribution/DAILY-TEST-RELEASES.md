# Unattended Mac test builds

After this PR is merged, run `python3 scripts/install-daily-test-release.py` on
drmeyers, using an installed Python3.9+ with venv and zoneinfo. The installer
defaults to a stable entrypoint for its running interpreter; `--python /absolute/path/to/python` selects
another installed runtime. It recovers stable Homebrew opt/bin or system launcher paths when framework
launchers expose a versioned Cellar binary; explicit paths preserve symlinks.
The agent and release helpers use that same interpreter, without a specific
Homebrew formula or a bare-python PATH assumption. It installs only main into a private dedicated checkout and starts a
local LaunchAgent. It does not install a GitHub self-hosted signing runner or move
credentials. A loaded agent must finish and be unloaded before reinstalling.

The agent checks for due09:00/14:00/20:00 Europe/Berlin slots, including DST and
missed wakes, and for successful `Request Mac test release` workflow_dispatch
requests on main. Minute pulses discover requests; in-progress CI leaves the slot/request pending
for up to 45 minutes across minute pulses (with a 3-minute start grace when a
fresh main commit has not registered its workflow run yet), and admits the newest
unpublished green ancestor seen during that wait if main fast-forwards into
another in-progress run. Completed red CI or an expired wait consumes the
slot/request as a skip without signing. Waiting notifications are deduplicated
per slot, manual request and main SHA, then cleared on admission or skip. A green unchanged main
consumes the slot as a skip; failed admitted builds wait for the next slot. Manual workflow status records a request,
not the result of signing. Results/skips and one-line failures go to
`~/dev/cassini-coordination/NOTIFICATIONS-MAC-TEST-RELEASES.log`; private state,
logs and notarization reports stay under `~/.local/share/cassini-mac-test-releases`.

Build admission requires current main with its latest own-repository
push CI green. Scheduled nightly and manual perf-gate runs, as well as
paginated PR/fork results, neither authorize nor block it. The admitted SHA stays pinned through signing and publication. Unchanged main
skips. Build numbers are reserved atomically and include failed attempts/drafts.
A stale project version advances beyond the highest published stable patch,
so post-release betas never claim an already shipped version.
Each release has an immutable `vVERSION-beta.N` tag, a nightly title, and [user-facing notes](../docs/release-notes.md) from unpublished fragments.
User text is under500 UTF-16 units and also uploaded as plain text and HTML.
Developer PR titles are folded below it only on GitHub; they are literal code
spans with control characters removed. Failed uploads remain drafts; nothing is
clobbered, deleted or sent to cassini.talk/Sparkle. Test apps disable public
updates and contain no public feed URL.

Existing local signing/notary credentials are reused. Build and DMG creation take
the shared heavy lock separately (60-minute acquisition bound, matching the iOS
archive that shares the host); the DMG wrapper allows75minutes including
its60-minute lock wait and10-minute image task. The complete signed job has a
6-hour bound covering both lock waits, both notarizations and build time. Network/notary
waits hold no heavy lock. Build admission requires25GiB free, preserving a10GiB
reserve (when DerivedData is configured on an external volume via the Aqua
runner, `disk reserve` keeps13GiB on the internal disk and preflights external
mount,25GiB space and write access before reserving a build number); DMG admission requires13GiB and both reject memory pressure/growing swap.
Outputs stay on drmeyers's internal disk while DrMeyers2 is unavailable. Successful
job outputs are removed after publication. Failed owned job directories are
marked only after the child exits, then their products/DerivedData are pruned.
Keep at most three private diagnostic archives, each containing at most five
1MiB log/report tails plus its ownership marker. Startup also retries pruning
marked failed jobs before disk admission. Active, unmarked or symlinked jobs,
unowned archives and shared caches are never removed. Diagnostic-copy failure
retains the products and reports the cleanup problem.
No installer or signed build has been run as part of the pipeline-only PR.
