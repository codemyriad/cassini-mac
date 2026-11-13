# WP5: Transcribing (L-45, L-48)

The desktop meeting pane puts the transcription status below the title and date,
with an accent spinner, thin indeterminate bar, Stop and a chevron for details.
Audio remains playable. Running and queued meetings show no partial transcript,
Find field, speaker rows, listening excerpt or companion suggestion. Completed
meetings retain the WP3 transcript and player. User-paused progress keeps the
existing resume behavior.

The details popover contains the shared work labels, Model, Speed, Time left,
Audio done and Words so far; Battery at finish appears on a Mac with an internal
battery. The worker currently reports a model and coarse ETA but no reliable
stage, fraction, speed or battery forecast. Unreported values use an em dash;
steps have no fabricated completion checks. ETA is never converted into a fake
percentage. The shared catalog remains pinned verbatim; the absent Speed label
is localized in the Mac-only catalog. Unknown and under-minute ETA use existing
shared forms.

Both Stop actions call TranscriptionQueue.stop. Its existing persisted pause
transaction, worker shutdown barrier and partial-sidecar preservation remain in
charge. Frozen screenshot inputs and opened read-only files cannot invoke it.
No capture, audio, transcription-worker or persisted-schema changes are made.

Proof includes paired Transcribing and details boards with a laptop fixture,
assertions that the running vector's existing words remain hidden and that audio
stays available, and a generated-input UI test that stops from the popover,
resumes, and stops again from the heading. The finished-meeting board uses an
app-owned completed copy of the running vector; sealed inputs stay unchanged.
Local checks use targeted Swift tests and xcodebuild build-for-testing. Actual
app/UI execution and light/dark capture run on hosted CI.

Stack: WP1 foundations → WP3 meeting → WP4 recording → WP5. The draft will be
opened after WP3 is rebased onto merged WP1 and WP4 is opened, per seat ordering.
