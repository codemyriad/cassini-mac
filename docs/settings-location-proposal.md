<!-- SPDX-License-Identifier: GPL-3.0-or-later -->
# Library relocation on macOS (D15.1)

The app and native browser host share a Mac-local version 1 pointer at
`~/Music/.cassini-library-location.json`. It contains `primaryPath`,
`previousPaths`, app-scoped `bookmarks`, and a per-folder `pendingMoves` journal.
The fixed Music anchor remains accessible after the Library moves. Absence means
Music/Cassini; malformed data fails closed. A missing configured primary is never
silently recreated by recording/import. The GUI resolves its security bookmarks;
the unsandboxed browser host uses the GUI's published path instead of resolving
bookmarks belonging to another signing identity.

Move durably publishes the destination and complete folder plan before moving
anything. New captures/imports use the destination at once. A short advisory
routing lock coordinates destination publication with folder creation; existing
captures hold no routing lock, and independent new captures can share it. A host
connected before Move resolves the pointer only when it accepts a new start.

Idle meetings move individually with an exclusive, no-overwrite rename on the
same volume. Cross-volume movement stages a whole tree, compares every file's
size and SHA256, checks source identity/mtime/size, and syncs it before publishing.
Only then is the original retired by atomic rename. Failure leaves the complete
original. A conflicting destination is untouched. Retained originals remain
readable, including a separate selectable row when folder names collide.

Capturing, saving, unreadable producer sessions and locked inference jobs stay
at their original paths until idle. A real inference child is neither cancelled
nor rebased. Only pending scheduling and imports pause during movement; playback,
export and detail views close after notes flush. Readers retain old roots until
all pending/failed folders resolve. Search is rebuilt afterwards. Failed folders
are retried only by Try again; automatic retries concern pending folders only.
The journal survives Quit, cancellation and relaunch. A restart reconciles folders
already moved before the journal update without overwriting anything.

The Settings lines use catalog moving/waiting/failed copy, plural forms, and a
human-readable old folder path. No meeting/session/audio format or shared browser
wire change is introduced. Capture audio and mute behavior are unchanged; D18's
independent sessions and source-before-mute requirements still apply.

`swift test --filter 'LibraryMoveTests|LibraryLocationTests|BrowserConnectionTests'`
checks journal compatibility, collision retention, cancellation, size/hash copy
validation, real inference locks, late routing and independent connection leases.
`scripts/test-settings-app.py` runs two fresh app processes over private generated
files and RAM audio: Carbon shortcut replacement/conflict, per-meeting failure
and retry, live/inference path preservation, Search rebuilding, a preconnected
browser host's late-bound destination, and pending movement after relaunch.
It opens no audio devices and changes no user Library/configuration. It does not
exercise a real external volume, picker interaction or hardware mute behavior.
