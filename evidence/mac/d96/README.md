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
Unedited audio-only Opus bytes remain original; known Cassini documents use the existing
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

## Validation

- 356 affected Kit/Library/Export headless tests pass after ordinary merge of
  main `d776181` (#210 and #244 included). The existing security-scoped bookmark case
  remains assigned to login-session CI.
- The arm64 native app builds with Xcode 16.4. The actual sandboxed coordinator
  proof passes in the dedicated console user's Aqua session: multiple/ZIP
  import, dedup, all/selected stored export, original audio bytes, queued cancel of fresh content with no new publication,
  stale save choice rejection and all locale summaries. No devices are opened.
- 56 CI contracts, shared catalog hash/used-copy checks and whitespace checks
  pass. An additional own-capture test encodes real PCM into a complete Cassini
  archive entry with its UTC start and saved annotation.
- Nine real production mutants fail behavioral assertions, without expectation
  timeouts. Restored core tests pass; source hashes are in `checkpoint.json`.

| Production mutation | Assertion |
| --- | --- |
| [unsafe-paths.patch](unsafe-paths.patch) | Parent paths must throw; late unsafe entries publish no member |
| [entry-count.patch](entry-count.patch) | 2,001 entries refuse the archive |
| [ratio.patch](ratio.patch) | Declared, padded and forged deflate ratios refuse the archive |
| [crc.patch](crc.patch) | Corrupt member fails while the good member imports |
| [runtime-budget.patch](runtime-budget.patch) | Actual expanded bytes cannot exceed the archive budget |
| [dedup.patch](dedup.patch) | Repeated content is a duplicate, not another imported note |
| [selected-completeness.patch](selected-completeness.patch) | Missing selected member fails the whole output |
| [local-title.patch](local-title.patch) | User renames survive import elsewhere; opaque local edits refuse export |
| [chunk-cancellation.patch](chunk-cancellation.patch) | Cancellation after the first chunk stops further reads |

The independent stdlib fixtures and Python reader also cover ZIP64 stored
output, the exact decimal 20 GB boundary without huge allocation, 2,000/2,001
entries, encrypted central/local flags, unsafe Unicode aliases, symlink/nested
skipping, runtime lengths, complete words/notes, original byte retention,
long Unicode names and collision suffixes.

Run `scripts/test-bulk-transfer-app.py APP --output OUTPUT` under heavy-run with
`CASSINI_LOCAL_WORKFLOW_TESTS=1`, in the actual console user's Aqua session.
It fails early in the wrong local user session; hosted CI uses its real GUI
session. The first post-reboot Background-session attempt timed out without
reaching the app proof; the proper Aqua run found a fixture subdirectory typo,
which was fixed. Successful source/build/GUI logs and discarded attempts stay
under `~/coordination/evidence/big-mac-d96/`. Verification assets are privately
cached and checked by the existing source-pin/unsigned-digest validator.

Run `D96_EVIDENCE_DIR=EXTERNAL ~/bin/heavy-run python3
 evidence/mac/d96/replay-mutations.py` with Xcode 16.4/SDKROOT selected and no
concurrent build reading this checkout. It restores each source in finally,
then reruns the core slice. Generated portable patches/receipts go under the
external `public-mutations` directory. No user files or permissions are changed.

The D96 branch remains independent of #248. Publish ONE draft after #248 is
ready, include current main by ordinary merge, complete D87, and do not self-merge.

## Native cancellation and stale choices

Queued cancellation now checks parent cancellation before worker I/O. Its
fixture contains fresh content, not a pre-existing duplicate, and requires zero
imports/duplicates plus identical Library IDs. Native guard mutations
[native-queued-cancel.patch](native-queued-cancel.patch) and
[native-stale-save.patch](native-stale-save.patch) respectively remove actual
task cancellation or the production save-choice generation guard. Each fails
the real sandboxed publication assertion without a timeout. The source and
native product are rebuilt/restored; the normal proof passes afterward.
`native-mutations.json` records the outcomes. A manual proof refuses to run
while the dedicated GUI runner has an active worker; queued CI runs its own
proof in its assigned session. Full native build/mutant/restored logs are in
the external evidence directory.

`replay-native-mutations.py` repeats those two actual-app mutants. Supply
`D96_NATIVE_APP`, `D96_BUILD_COMMAND_JSON` (the xcodebuild argument array),
`D96_EVIDENCE_DIR` outside the checkout and any verified build-asset environment.
The caller normally runs in Aqua; `D96_GUI_PREFIX_JSON` can wrap only the proof
command when a dedicated console account is used, with `D96_PROOF_OUTPUT` in
that account's writable private directory. Run the whole script under heavy-run,
with no concurrent build of this source. On interruption it restores source
without starting another heavy build; the private app must then be rebuilt.

The actual sandboxed Settings/move/relaunch proof also passes, including import
intent resuming at the new root, deferred work and retained selection. The local
Debug app bundles the same generated Library fixtures as CI. Its first attempt
without those fixtures failed during initial import and is retained externally;
it did not reach the move checks. The independently included DEBUG native footer
observer and real-host layout are identical to #248 at `698dad9` (its native
transition assertions/mutations are linked from that PR). Release behavior is
unchanged; this avoids depending on the D95 feature branch for a reliable proof.
