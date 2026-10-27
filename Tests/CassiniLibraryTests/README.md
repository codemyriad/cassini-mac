W1-M2, HARMONY §§3/4/6 and DECISIONS-UX D1/D2/D3.

The 64 format and 15 state cases are coordinator-owned, copied byte-for-byte. SHA256
assertions pin format v2 and state v1; no local golden adjustments. Run:

    TZ=UTC LANG=C swift test --filter Library

Scanner tests use temporary roots and captured format fixtures, never the user's Library,
audio devices or browser. They cover received/plain/damaged transcripts; speaker order and
quote selection; activity vs abandoned/saving; interrupted/gap history; stale WAV/header
sizes; unreadable capture metadata; missing tracks; path/symlink rejection and read-only
ownership. FSEvents is a separate module behind LibraryWatching and is tested in a temp root.

No app scene, UI, writer/importer, cache/index, processing engine or capture protocol changes.
Target boards inform the model (02/04/06/08/12/18/30); no screenshot/pixel claim in this PR.
