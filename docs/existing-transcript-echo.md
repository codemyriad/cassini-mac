# Existing transcripts (D38.6)

On discovery, the Library schedules a model-free background pass for saved own
meetings with a completed transcript and both microphone/local and comparison
sources. Regular transcription takes priority. The pass reuses the saved words
and decoded raw mono levels; it never constructs VAD or a recognizer.

Every raw word and extra JSON member is retained. Only confirmed repeats gain
`echo: true`. Metadata and producer audio/session bytes are untouched. Missing,
unsafe or unsupported input is skipped. A saved speaker that maps to overlapping
physical spans is ambiguous: those words remain visible.

The private `.cassini-echo-v1.json` sidecar binds completion to the word-file hash.
Unchanged transcripts are never classified again. Atomic writes, the existing
transcription lease, hash-bound recovery and abandoned-draft cleanup make an
interrupted pass resumable. New transcription also writes the marker.

The queue cancels and joins maintenance before manual recording. Automatic
capture announces preparation before file creation; checkpoints cancel the pass,
and the final short publication transaction is serialized with that admission.
Move, Trash and Quit use the existing queue cancellation/drain mechanisms. The
pass resumes on idle rediscovery or next launch; it does not change transcript
status or display a progress message.

Frozen pre-D38 clean/bleed/room transcripts are hash-pinned under
`Tests/CassiniTranscriptionTests/Fixtures/Echo/PreD38`. The model-free tests cover
unchanged words, levels and sources, both missing source kinds, ambiguous and
nonoverlapping microphone spans, missing audio, cancellation, concurrent edits,
leases, crash drafts and stale markers. The hosted app probe additionally checks
automatic discovery, recording preemption, idle resume and the publication gate.
