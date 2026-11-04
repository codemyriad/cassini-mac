# meeting.json ↔ Library v2 Cassini file (S-12 §3, with the §11 answers)

Schema: `x-schema.json` (`x["codemyriad.io"]`, `schema: 1`). Its member types are `$ref`s into
`../meeting.schema.json`, so the two can't drift. "Qn" refers to the answers in S-12 §11.

## Field table

| meeting.json member | Cassini file location | Notes |
|---|---|---|
| `id` | `x["codemyriad.io"].sessionId` | Verbatim. Not the manifest `meeting.id` (that stays `mtg_<opusAudioSha256>`). |
| (folder prefix `Recording-`/`Received-`) | `x["codemyriad.io"].origin` | `Received` iff `received` is an object. |
| `revision` | `x["codemyriad.io"].revision` | See "Ordering and revision" (Q9). |
| `namePrefix` (optional v2 member, Q11) | `x["codemyriad.io"].namePrefix` | Chosen once by `names.py`, never recomputed. |
| `namePrefixSource` (optional v2 member, Q12) | `x["codemyriad.io"].namePrefixSource` | `recorded` \| `legacy-device-tz` \| `date-tag` \| `import-time`. Present ⇄ present, absent ⇄ absent; never in passthrough (see the rebuild rule). |
| `published` (optional v2 member, Q11) | nowhere | Session-local: the file existing is the fact. |
| `version` | `x["codemyriad.io"].meeting.version` | |
| `title` | `x….meeting.title` verbatim (may be null) | Manifest `meeting.title`, `TITLE` tag and the file name use the **displayed** title instead. |
| `titleSource` | `x….meeting.titleSource` | With `automaticTitle` it makes up the D38.4 automatic-name state. |
| (session.json `title`, or a received file's original title) | `x["codemyriad.io"].automaticTitle` | Q1. Captured at first publish and updated whenever the automatic name changes. A blank rename restores it without a session folder. |
| `notes` | `x["gocassini.com"].notes` | D13, Q13: the same objects in the same order, unknown note members kept. Key omitted when `notes` is `[]`, so absent means `[]`. Other `gocassini.com` members are carried forward. |
| `speakers` (id, name, provenance, colourIndex, nameCleared, unknowns) | `x….meeting.speakers` verbatim | Also projected into manifest `speakers` (below). |
| `speakerMerges` | `x….meeting.speakerMerges` verbatim, ordered | Absent stays absent. Q2. |
| `transcript.status`, `.model`, `.reference`, unknowns | `x….meeting.transcript` verbatim | The words themselves live in the default `words` transcript (Q14). |
| `etaMinutes`, `error` | `x….meeting.etaMinutes`, `.error` | Transient, so they reach the file only with the next journaled operation (Q9). |
| `quoteOverride` | `x….meeting.quoteOverride` | |
| `received` | `x….meeting.received` | `sha256` stays the original file's hash (UX4 duplicate check). |
| `recordingDetails` | `x….meeting.recordingDetails` | Absent stays absent. In the coordination schema, not yet in GNOME's vendored copy. |
| any other top-level member | `x["codemyriad.io"].passthrough.<name>` | As-is, including integers above 2^53. |
| (unknown track offsets mixed at 0) | `x["gocassini.com"].recovery.offsetsAssumedZero: true` | Q7: the only home (D19). Never written in `x["codemyriad.io"]`. Conversion keeps an existing marker. |
| (session.json tracks, §4.3 spans) | `x["codemyriad.io"].tracks` | Provisional until step 3. |

## Manifest members and tags (projection, not stored state)

- `meeting.title` = `TITLE` = the displayed title. That is the first non-empty of: `meeting.title`, then
  `automaticTitle`, then a received file's original name stem, then the catalog's `library.untitled`. The catalog
  string is stored in the writing app's language at first publish; a later locale change doesn't rename the file
  (Q6b). The file name is `names.py` applied to the same string.
- `DATE` = the start of the meeting, `YYYY-MM-DDTHH:MM:SS±HH:MM`, seconds floored (Q8). Export's DATE becomes the
  start too. `meeting.recordedAtLocal` carries the same wall clock without the offset, only from a known start
  (D19). `meeting.createdAtUtc` = publish time (format rule). Received files keep their own values.
- `speakers[]` (Q2) = one entry per **original** speaker id the transcript uses, with `label` set to the name after
  resolving `speakerMerges`, so merged ids share a label. An unnamed speaker gets the catalog label ("Speaker N")
  in the writing app's language. An app that sees `name: null` in our `x` re-localizes it for display.
  `CASSINI_SPEAKER_COUNT` = the entry count. Merge and undo rewrite only the manifest `speakers` and `x`, never a
  transcript body. Export (outside the Library) keeps its own merged form.
- `transcripts` = the default `words` entry. Its body keeps the original speaker ids and is never rewritten for a
  merge (D24). Before transcription completes it is the empty body from §3; it is never an empty array.
- Provenance, other transcripts, attachments, unknown members and tags: carried forward unchanged (§6).

## Source of truth for the words (Q14)

In v2 the file's default `words` transcript is the truth. `transcript.json` stays in the session folder only as
the transcription working copy until the transcript is committed into the file. If the two differ and no journal
entry is pending, readers trust the file. `transcript.reference` is still carried verbatim, for the round trip.

## Files without our `x` (Q15)

A gocassini or hand-copied file is identified by its `opusAudioSha256` until we first edit it. That first edit of
any kind (rename, title, notes, speakers) is one journaled operation. It creates a `Received-<uuid>` session and
adds `x["codemyriad.io"]` at `revision: 1`, with `received` filled from the file. Notes-only edits go the same way.

## Rebuilding meeting.json from a file

```
meeting.json = { "id": x.sessionId, "revision": x.revision, "namePrefix": x.namePrefix,
                 "notes": x["gocassini.com"].notes or [], **x.meeting, **x.passthrough }
if "namePrefixSource" in x: meeting.json["namePrefixSource"] = x.namePrefixSource
```
`namePrefixSource` round-trips by presence. If meeting.json has it, `x.namePrefixSource` holds the same value. If
meeting.json lacks it (for example a legacy v1 meeting converted before Q12), `x` lacks it too, and the rebuild
doesn't add it. It never goes into `passthrough`, and the schema rejects it there.
Plus `published: true` when a session folder exists. A key in both `meeting` and `passthrough` is invalid.
Writers split the other way: the members `x.meeting` lists go into `meeting`. Everything else except `id`,
`revision`, `notes`, `namePrefix`, `namePrefixSource` and `published` goes into `passthrough`.

**Equality (§9.7)** is JSON-value equality over the v1 members (Q11): object member order is ignored, array order is
significant, numbers are compared exactly. meeting.json is written compact, so byte equality isn't required.

## Ordering and revision (Q9)

- Arrays keep their order: notes, speakers, speakerMerges (history order matters for undo) and passthrough values.
- Every journaled operation (§7) writes the file and meeting.json at the same new `revision`.
- meeting.json may run ahead of the file without a journal entry, because transient writes (`etaMinutes`,
  queued/running status, `error`) bump only meeting.json. They reach the file with the next journaled operation, and
  at the latest when transcription finishes or fails.
- The file is never ahead of meeting.json without a pending journal entry. Recovery replays the journal, and the
  higher revision wins.

## What stays only in the session folder

- **session.json** (capture-owned, never rewritten by the app): `createdAt` and `startedAtUtcOffsetMinutes`
  (surface only as DATE / recordedAtLocal / namePrefix), `source`, `state`, `problemKind`, `events`, raw track
  entries (`ended`, `gapFrames`, …; their placement facts are copied into `tracks`), and `title` (mirrored into
  `automaticTitle`).
- **speaker-turns.json** (D24 cache, never exported), `.meeting.lock`, the WAV/Opus spans themselves, and
  `published`.
- **transcript.json**: the working copy until it is committed (Q14).
