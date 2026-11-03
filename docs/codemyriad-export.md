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

A file that already carries `x["codemyriad.io"]` from another writer keeps it
through import and re-export. With nothing changed on Mac, or with a schema this
app does not know, it comes back byte-for-byte. In a schema-1 copy, Mac's changes
replace those members in place (D55.1), and every other member stays verbatim:
- title and titleSource, and the speaker names the user set or cleared;
- a Write down on Mac: transcript `status`, `reference` and `model` (with
  `etaMinutes` and `error`) once they differ from what the import stored; the
  speakers it added, appended whole; its `label` for a speaker id both writers use
  (a received file's `track-original`); and its `recordingDetails.writingDown`
  facts, with the other writer's unknown facts kept.

Its `revision` follows MAPPING Q9 (higher wins). A notes change counts too, since
a rebuild takes notes from `x["gocassini.com"]`. Notes as the import kept them
(`LibraryImport.importedNotes`: atMs and text of each valid note) do not count. Each export whose content (the
namespace's `meeting` plus the notes) differs from the last one Mac exported takes
the next revision above both the original and that last export. An unchanged
re-export keeps it. Mac keeps that baseline in its own meeting.json, as
`codemyriadExport: {"revision": n, "sha256": hex}`. The content is read, and the
baseline compared and advanced, under the folder lock before the file is written,
so a revision never names two contents. It is never exported, not even in
`passthrough`. Metadata Mac does not rewrite (an unsupported version or invalid
metadata) cannot change on Mac either, so it is decided without saving. A revision
at or past 2^53-1 is never advanced: the original namespace is kept.

A plain Opus file (no manifest) is trusted like a Cassini file for its DATE and
TITLE tags: they choose the namePrefix (`date-tag`) and `automaticTitle` (TITLE
trimmed, a blank one skipped, as the import does).

The Library v2 file name (`LibraryNames.fileName`) is ported and vector-checked
here, but Mac's Library and export file names are not changed by R65.

## One read per export (#116 review r3)

Each export attempt reads the meeting folder again (`LibraryScanner.meeting(at:)`)
and takes the words, speakers, title, notes and namespace from that one read.
Every change to the words bumps meeting.json's revision, and the namespace checks
that revision (under the folder lock for another writer's copy); if it moved, the
export reads again. The words' digest is part of the revision baseline, and a body
that differs from the original file's counts as a change.

- Notes: while Mac's notes equal what the import kept, the original note objects
  go out verbatim, unknown members included.
- The manifest `speakers` list only the speakers of the exported words (none while
  a Write down is still running).
- Words the export reads as damaged are written as `transcript.status: damaged`
  in the namespace, never as done.
- For another writer's copy, the manifest title and TITLE are the title its
  namespace implies (`meeting.title`, then `automaticTitle`).
- Our own namespace is written only from a real meeting.json. A file opened from
  outside the Library keeps any namespace and notes it has, and gets none made up.
- The first export of a folder without meeting.json (legacy, with a transcript.json
  the Library reads as done) creates meeting.json referencing those words.
- A namePrefix that could not be saved fails the export with
  `libraryFolderNotWritable`, as a revision that could not be saved does.

## Refusals and the untitled fallback (D65)

- Another writer's namespace with a schema this app does not know, a malformed
  one, or a revision outside 0…2^53-1 refuses the export (`newerFormat`, shown as
  `export.failed.newerFormat`, no Try again), even with nothing changed on Mac. So
  does a schema-1 namespace at 2^53-1 when a change would need a higher revision;
  an unchanged one still goes out unchanged. A file opened from outside the
  Library is refused the same way.
- A meeting without a title (a recording with no meeting-window or user title)
  saves the catalog's `library.untitled` in the language of its first export, in
  meeting.json's Mac-local `codemyriadExport.untitledTitle`. Later exports use it
  for the manifest title and TITLE, so a language change never changes the title
  under the same revision. `x….meeting.title` stays null.

## Known limits

- The revision baseline lives in the meeting folder's meeting.json. Trashing a
  received meeting and importing the same file again starts from the file's own
  revision, so a revision Mac exported before can be reused for other content.
  Accepted (D65, D51): there is no Library-wide record.

## Edge revisions (#116 review r4)

- Our own namespace keeps the digest of its last export with the revision it went
  out at (Mac-local `codemyriadExport.own`). Other content at the same meeting.json
  revision (words that became unreadable, or were restored) first advances
  meeting.json's revision under the folder lock; the same content keeps it.
- Metadata Mac may not rewrite (an unsupported version or invalid meeting.json)
  can't keep that baseline, so such a recording's export carries no namespace of ours.
- Another writer's namespace is validated before anything else, in or out of the
  Library: schema 1, a meeting object, a revision in 0…2^53-1, or `newerFormat`.
- A trusted file opened from outside the Library that carries our namespace is
  exported byte-for-byte, so none of its transcripts is dropped under its revision.

## Carried, never rebuilt (#122 review, MAPPING §6)

A received file's transcripts go out byte for byte: every manifest entry, also one
this app can't read, and exactly each declared chunk set's tags. Display
transcripts (`readableTranscripts`) keep their payloads, and a withdrawn
transcript's leftover `CASSINI_TX_` tags are dropped. Only once Mac's own Write
down has finished do Mac's words become the default transcript; the originals stay
beside them, unchanged and no longer default, and the original `provenance` (about
the old default's words) is dropped. While a Write down is queued, running or
failed, nothing in the file's transcripts changes.

The file's other top-level members, the meeting's and audio's unknown members, its
speaker entries (with the user's names from meeting.json; Mac's speakers follow
only with Mac's own words), and its tags Mac doesn't write (DATE, ARTIST,
DESCRIPTION, ENCODER, unknown `CASSINI_` facts, also from a plain Opus file) are
carried too. `CASSINI_TRANSCRIPT_IDS` lists the ids sorted. `createdAtUtc` is
still the export time until the D65 follow-up.

## Speaker labels and read-only Libraries (#122 r3, #116 CI)

- The manifest labels a carried speaker as the namespace says: a name the user gave
  on Mac, or, for a name the user cleared, the catalog's unnamed label numbered by
  its place in the list. Other speaker members and the other writer's edits
  (`speakerMerges`, voice links) stay unchanged.
- A Library that can't be written at all (a screenshot fixture, a read-only volume
  or copy) is no app-owned folder fault: its exports carry no namespace of ours
  instead of being refused. Only a writable Library whose meeting folder can't be
  written refuses (D65). This is probed only after a save failed.
