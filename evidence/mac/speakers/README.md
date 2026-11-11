# Mac speaker parity: D24 UX16 / M4

Audit: cassini-ux `febfcc0bbd7db4b06096e87f5490d6773ab9224e`,
PARITY.md and decisions/DECISIONS-UX.md. PARITY's 6-November cells lag current
source; the full missing-row inventory is in the coordinator's STATUS-BIG-MAC.md.
D24.5 approves manual speaker names, explicit clear, merge and undo, and the
longest-turn sample capped at ten seconds with position restored paused.
D70.11 explicitly deferred these Mac actions until this M4 naming sheet.

Two shipping references:

- [Android NoteViewModel / document repository](https://github.com/codemyriad/cassini-android/tree/231c4252b2588a22fcc9ead718bd41be04e80a4f): names, clear and ordered merges.
- [iOS speaker sheets](https://github.com/codemyriad/cassini-ios/tree/0cc9d7229893519b74c72c6a4ba3f92c397718ec/Cassini/Features/Speakers): NameSpeakerSheet and MergeSheet.
- [GNOME speaker edit core](https://github.com/codemyriad/cassini-gnome/blob/dc885d6519e1e42ad7509d5df834afdd72c94997/src/cassini_talk/speaker_edits.py): fresh visible-ID validation, scalar/control validation, explicit nameCleared and ordered history.

## Audit disposition

| Mac source gap | Decision | Disposition |
| --- | --- | --- |
| Speaker name / clear / merge / undo and sample | D24 UX16, D70 M4 | This draft |
| Shared-source diarization / speaker-model Settings | D24 UX15 | Separate runtime/UI work |
| Saved voices / CAM++ recognition | D25 UX17, D56, D64 | Separate model/profile/UI work |
| Finished-meeting file-backed Library | D44 | Separate storage transition |
| Recording-time reader/producer parity | D95 | Existing #248 |
| Multi-file / ZIP import and ZIP export | D96 | Other agent, existing #253 |

Mobile-only bookmarks/stars/passage edits (D53.1), lock-screen recording controls
(D53), additional mobile subtitle exports, and platform engines/chrome are
intentional differences. Tags/summaries have no approved two-app desktop design.
Mac already has speed, per-speaker listening, six languages, automatic browser
capture, Parakeet adoption and system dark appearance despite stale table cells.

## Implementation and verification

The naming dialog uses the shared catalog and the existing serialized metadata
worker. Its working state already fences Library move, Trash, Quit and updater
installation. It retains security-scoped Library access throughout off-main
validation, atomic metadata publication and rescan. Display facts are computed
off the main actor. Direct-open files, read-only/unsupported metadata, active
captures, transcription in progress and unowned roots cannot be edited.

The core rereads state and resolved visible IDs inside the metadata directory
lock. Name input is trimmed, limited to 64 Unicode scalars, and rejects controls
and formatting controls. Clear writes name:null / provenance:unnamed /
nameCleared:true; a subsequent name removes that flag. Original producer labels,
voiceSource, notes, unknown fields and number spelling use the existing preserving
writer. Merge appends only different currently visible IDs; Undo removes the
last raw history entry, including one a reader ignored. Transcript/audio bytes
are never rewritten. Existing scanner, Search, Markdown and portable projection
consume these edits. Portable export retains raw word IDs and the merge history
in x, and projects the target name onto each raw ID's label, as D70 requires.

Sample playback uses the ordinary precise transport span. The callback and
Cancel restore the previous position paused; replacing/cancelling a sample
fences obsolete seeks and span callbacks. Selection uses the longest chronological
speaker turn, capped at ten seconds; talk time unions overlapping word intervals.

Validation logs remain outside the checkout at
`~/coordination/evidence/mac-speakers/`. The mutation replay applies only
committed production patches in sequence, requires executed behavioral failures,
and restores sources in finally. Run it under heavy-run with Xcode 16.4, SDKROOT,
verified CASSINI_OPUS_ASSETS and an external SPEAKER_EVIDENCE_DIR. Do not build
this source checkout concurrently while applying mutations.

Final headless validation: 365 affected tests and 56 CI contracts pass; all used
catalog IDs validate. Ten real production mutations fail assertions (including
the zero-duration anchor regression, which failed before its fix); source files
restore byte-for-byte. The 122,760-word facts case takes about 184 ms thread CPU
against its 5 s bound. The actual acknowledgment vector covers a chip-only
speaker. French fallback names with American regional formatting use the
catalog; original producer labels remain verbatim.

The Debug arm64 app and Screenshots bundle compile under Xcode 16.4. The local
native test has exercised rename, invalid-name rejection, Cancel and Clear.
Its Merge query was corrected to use the native menu's accessibility role;
the final full UI flow is pending local build capacity at draft publication.
Earlier local test-plan/fixture setup failures and the corrected fixture
selection are retained in external logs and are not counted as passes.

## Native control follow-up

The exact-head CI run at 2c72b3a passed
`testSpeakerNamesClearMergeUndoAndReopen`, including persistence across relaunch.
Its three other board failures exposed old assumptions: Name/Merge controls
were absent, and speaker names/shares were static text. Those checks now use
real named controls; the speaker button exposes its share as accessibilityValue.
A native arm64 rebuild passes. In a genuine Aqua session the listening-bar test
and complete rename/clear/merge/undo/reopen flow pass, as do all new share-value
assertions. The four-test run as a whole remains red: the existing Meeting title
geometry is 250 rather than expected 280 (tracked separately by #251), and the
record/retry test never leaves its failure state on this local fixture. No
assertion bound or timeout was loosened, and neither failure is counted as a pass.
Logs and xcresult receipt: `~/coordination/evidence/mac-speakers/review-ui*`.
