# W2-1: Library shell and first run

The app now opens one Library Window backed by CassiniLibrary/LibraryWatchers.
Selection keys use the prefixed folder basename. Snapshot IO runs in a detached
task, serialized by the store; native activity changes invalidate their affected
folders even without a filesystem event (review #3 note 1). Browser/broker and
Saving activity integration remains UX5. The other three review notes are fixed.

The list groups by the model's calendar days and uses its title, time, badge,
meta and quote. The preview reads the model's transcript items for three turns,
speaker chips/provenance and the subtitle. All new copy comes from the pinned
shared strings catalog; scripts/check-ux-copy.py checks the hash and used IDs.

Record opens the existing recording window until UX5. Session-folder Play is
visibly disabled until W2-2. Received Play opens the existing file viewer and
starts playback; externally opened files use that same viewer without import.
Read the transcript opens a read-only transcript view for session folders, and
the legacy viewer for received files; UX3 owns the redesigned Meeting page.
The Library's Music entitlement and real-user home path allow the literal
Music/Cassini root shared with browser hosts in a sandboxed app.

Known scope differences from the boards:
- No dead search field: search is UX12 per the checklist.
- Badge pills are included per the newer INBOX override. The live header is a
  read-only placeholder; real transport/levels are UX5.
- R11: session.json source=chromium identifies browser capture; only live browser
  rows show the catalog's browser meta and second line. Native/unknown live rows
  and Saving rows have no meta or second line. Transcribing rows show only the
  duration/audio-ready second line when duration is known.
- Legacy viewer/recording windows retain their existing UI until their milestones.

Hosted-only S-4: ux-boards.yml builds the shared main/empty input cases into the
app bundle, uses now=2026-10-27T14:18 Europe/Rome, en_GB, light appearance and default
blue accent. XCUI captures the actual complete window at exactly 1120x720. Artifact
ux-boards contains library.png and first-run.png. Local validation compiles UI
only; all execution/screenshots use an ephemeral GitHub-hosted macos-15 display.

The follow-up for boards 02/04 uses a 7px rounded selection with 8px horizontal
insets, an explicit bold leading Library toolbar title in the populated view,
and a centred bold title on first run. The native window title remains available
to the window system while its standard drawing is hidden to avoid duplication.
