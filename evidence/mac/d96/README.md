# Mac D96 checkpoint

Contract: cassini-ux main D96; shared catalog bytes/pin `4d57737`.
Reference behavior: Android #166 (`1a9842c`) and iOS #115 (`96d2457`).
The Swift ZIP/ZIP64 stream implementation adapts the latter with Foundation/zlib
on Mac, decimal 20,000,000,000 expanded bytes, and actual inflater-consumption
ratio checks including forged expanded lengths. Limits are 2,000 entries,
100:1 per compressed entry, no encryption, no unsafe central/local/Unicode
paths. Symlinks, directories and nested archives count unsupported. Every
member, including unsupported data, passes bounded runtime byte/CRC checks.
Archive paths never become filesystem destination paths.

Mac keeps its existing supported codec surface: Ogg Opus (`.opus`, `.ogg`).
Bulk imports call the ordinary lock/digest importer and keep completed notes
on cancellation. Private ZIP/member staging is removed on every exit.
The Library picker/drop route accepts several files and ZIP; native Library
selection supports all/selected stored ZIP export with collision suffixes.
Audio-only Opus bytes remain original; known Cassini documents use the existing
complete-document export including current notes. Opaque documents retain all
original bytes. Opaque documents with local-only edits fail the whole export
rather than silently discard those edits. Missing/unexportable selected notes
also fail the whole output. Filename generation keeps the existing naming
rule, adds numeric collisions and replaces colon for portable ZIP safety.

The app retains original security-scoped URL leases through detached work.
Progress/cancel/summary use the pinned catalog in all supported locales.
Quit and Library moves cancel/join work; incoming files during the move pause
wait for the new root. Cancelled save-panel callbacks cannot start a stale
export. ZIP output uses the existing sandbox-safe atomic SavePanel destination.

## Validation at reboot checkpoint

- 354 affected Kit/Library/Export headless tests pass. The existing security-
  scoped bookmark test remains assigned to login-session CI.
- Native app build and final incremental build pass on arm64/Xcode 16.4.
- Shared catalog hash/used-copy checks and diff whitespace checks pass.
- Tests cover independent stdlib deflate fixtures, Python reading stored ZIP64,
  exact decimal 20 GB boundary without allocating huge audio, 2,000/2,001
  entries, late unsafe/encrypted/Unicode aliases before any import, forged and
  padded deflate sizes, CRC, runtime budgets, corrupt/oversized members beside
  good ones, duplicate hashes, nested/symlink skipping, cancellation cleanup,
  all/selected exports, original bytes, complete words/notes and long names.
- The actual sandboxed coordinator proof is compiled but NOT YET EXECUTED.
- Eight production mutations are prepared but NOT YET RUN.

Resume: run `scripts/test-bulk-transfer-app.py APP --output OUTPUT` with
`CASSINI_LOCAL_WORKFLOW_TESTS=1` under `~/bin/heavy-run`. It uses only the
existing private RAM fixture and tests all/selected, dedup, original bytes,
queued cancellation and stale SavePanel rejection. The CI boards job now runs
it too. Run `D96_EVIDENCE_DIR=EXTERNAL ~/bin/heavy-run python3
 evidence/mac/d96/replay-mutations.py` with Xcode 16.4/SDKROOT selected, and copy
its successful portable mutation receipts here. That runner temporarily
mutates this checkout and restores every source in finally; run it while no
other build reads this worktree. Validate source restoration before continuing.

Full local logs/reference snapshots: `~/coordination/evidence/big-mac-d96/`.
No PR until #248 is ready; then ONE draft PR with D87, current main included
normally, under the four-PR cap. No self-merge. No dependency on the #248 branch.
