# The app's own namespace in exported files (R65, D55)

An exported Cassini file carries the app's private copy of the meeting in
`x["codemyriad.io"]` (schema 1), as defined by cassini-coordination
`ux-draft/library-v2/MAPPING.md` and `x-schema.json` (verbatim copies under
`Tests/CassiniLibraryTests/Golden/library-v2/`). The Mac Library itself stays on
meeting.json; this is only the file's copy, written by `CodemyriadNamespace`.

- `sessionId`, `revision`: meeting.json `id` and `revision`, verbatim.
- `origin`: `Received` when meeting.json `received` is an object, else `Recording`.
- `namePrefix`: a persisted meeting.json `namePrefix` is kept with its source.
  Otherwise `LibraryNames` (the `names.py` port) chooses it: Mac session.json has
  no recorded UTC offset, so a recording uses its capture start in the device's
  zone (`legacy-device-tz`); a received file uses its DATE tag (`date-tag`) or the
  import time (`import-time`).
- `meeting`: the meeting.json members MAPPING lists, verbatim and in order;
  absent members stay absent. Every other member goes to `passthrough`, losslessly
  (numbers keep their literal text, so integers above 2^53 survive).
- `automaticTitle`: session.json `title` for a recording; the original file's
  title for a received one.
- `tracks` (recordings only, provisional): one span per session.json track with
  `file`, `sampleRate`, `channels`, `frames`, `startOffsetMs` (null when unknown),
  plus the D52.4 `gaps`, `gapFrames` and `droppedFrames` when recorded.
- Notes stay in `x["gocassini.com"].notes`: meeting.json's own note objects, in
  order, unknown members kept. The offsets-assumed-zero marker stays only in
  `x["gocassini.com"].recovery` (D19).

A file that already carries `x["codemyriad.io"]` (another app's copy, or a schema
this app does not know) keeps it unchanged through import and re-export: Mac never
downgrades or rewrites it, and a Mac edit of such a received meeting shows only in
the manifest projection (title, speaker labels) and notes.

The Library v2 file name (`LibraryNames.fileName`) is ported and vector-checked
here, but Mac's Library and export file names are not changed by R65.
