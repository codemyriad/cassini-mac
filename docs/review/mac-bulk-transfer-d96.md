# Mac bulk transfer (D96)

The Library's Open picker accepts several Ogg Opus files (`.opus`, `.ogg`) and
ZIP archives together; drop accepts the same types. Command-click or
Shift-click selects Library rows. The Export menu offers all or selected
meetings as one stored ZIP. A running transfer shows shared progress/cancel
copy and a summary containing only nonzero counts. Completed imports remain
when the user cancels. Active recordings must finish before they are exported.

The Mac codec surface is unchanged. A ZIP member in any other format, a nested
archive, a directory or a symlink is ignored and counted as unsupported. Audio
and document bytes go through the existing content-digest importer, including
its per-file limit and metadata/publication locks.

## Archive policy and publication

The complete central directory and every local header's security facts are
checked before the first import: 2,000 entries, decimal 20,000,000,000 expanded
bytes, per-compressed-entry ratio at most 100:1, no encryption and no absolute,
parent or Windows traversal paths. Unicode path aliases are checked too.
Unsafe/encrypted/oversized directories refuse the whole archive. An archive
with no supported regular member reports empty. Individual damaged or
single-file-oversized members count failed while good members continue.

The container is privately snapshotted with stable source identity before
inspection. Stored/deflate input and ZIP64 use 64 KiB buffers. Actual expanded
bytes, cumulative budget, CRC, exact lengths and inflater consumption are
checked again during reading. Padded compressed sizes cannot hide a high
ratio. Unsupported members are read/discarded under those same bounds; nested
ZIP contents are never opened. A runtime-wide limit stops the remainder;
already committed imports remain, as with cancellation.

All scratch paths use private UUIDs. Entry paths are display text only and
reduce to a bounded basename. They are never extraction destinations. Staging
is removed on success, failure and cancellation.

## Complete exports

Export takes the requested ID set and fails the entire archive if a member
vanishes or cannot be included. It does not silently omit a selected meeting.
The directory is written once after all stored members, synchronized, then
published via the existing atomic sandbox-safe selected-file destination.
Partial archives remain private and are removed on failure/cancel.

| Input | Archive entry |
| --- | --- |
| Own PCM capture | Complete Cassini Opus through the existing encoder/exporter |
| Known Cassini document | Complete document including current notes/transcripts and preserved foreign payloads |
| Plain Opus without local content edits | Original Opus bytes/container |
| Plain Opus with a local title, notes or transcript | Existing complete-document exporter preserves those edits without changing the audio |
| Opaque/newer/damaged/stale document without local-only edits | Original document bytes |
| Opaque document with local-only edits | Whole export fails; unsupported metadata is not rebuilt and edits are not silently dropped |

Names follow the existing meeting export rule, with numeric collision suffixes
and a filesystem byte cap. Case/canonical-equivalent names collide. Colon is
replaced for ZIP portability, alongside the existing separator/control cleanup.
There is no archive manifest; every member is an independent document/audio file.

## Actor, sandbox and lifecycle boundary

Picker and drop retain the original URLs in security-scoped leases before
starting worker tasks. Save-panel choice is accepted only for its current
generation. Detached work retains those leases through its final I/O. Library
root bookmarks remain owned by the existing location model; Move cancels and
joins active work before replacing that access. Incoming files during the
pause wait for the new root. Quit cancels and joins both worker paths.

An already-cancelled parent produces a cancelled report before import I/O and
checks cancellation before starting export. Cancellation is also checked
between copy/inflate/encode/write chunks. Metadata and note-level publication
continue to use the ordinary single-file importer/exporter, not a parallel
ZIP-specific implementation.

## Evidence

356 affected headless tests, the arm64 app build, 56 CI contract tests and
shared-copy validation pass. Nine core production mutations fail behavioral
assertions. Two native mutations respectively disable actual task cancellation
or the save-choice generation guard; the genuine sandboxed publication proof
fails and passes again after restoration. Its queued-cancel input is fresh and
must leave the exact Library ID set unchanged. No success depends on a fixed
sleep; deadlines only fail hung harnesses.

Native proof runs in a real console Aqua session using private generated
fixtures. Manual invocation refuses the wrong user session or an active GUI
runner worker. Existing login-session bookmark/UI checks remain part of draft
CI. See `evidence/mac/d96/` for source hashes, patches and replays; full logs are
retained under `~/coordination/evidence/big-mac-d96/` on the coordinator Mac.

Reference implementations: Android #166 at `1a9842c` and iOS #115 at `96d2457`.
Shared copy is vendored unchanged from cassini-ux `4d57737`. The reader/writer
adapts the iOS stream structure; the decimal 20 GB limit follows the contract
and Android rather than that iOS draft's GiB value. No new package dependency,
user-data migration, network endpoint, signing identity or device access is added.
