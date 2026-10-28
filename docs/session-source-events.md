# Session source events

This implements the coordinator's binding S-6 draft in
`cassini-coordination/ux-draft/SESSION-EVENTS.md`. Shared protocol PR15 remains
under review; its unmerged snapshot is not vendored here.

A session may contain up to 1000 ordered `selection` and `othersSource` events.
`CaptureSourceState` projects them at a meeting-relative time. Older folders have
no inferred selection or fallback. Unknown event types/fields and malformed optional
provenance do not destroy playable audio or manufacture source history. Events are
not added to Cassini-file exports.

`RecordingSession.transition` publishes ended sources, new source/WAV pairs and
their events through one existing sync/temporary-file/rename checkpoint. It validates
the complete change before creating files. A new file left before publication is
an orphan; readers of a valid old manifest do not infer it as a capture. Track IDs
remain unique after a span ends. An ended track accepts no more audio. End offsets
remain derived from complete PCM frames; callers own input admission and tail
flushing before ending a source. This API does not select devices, implement a
fallback, or automatically restore a browser source.

A new browser span may carry the original opaque `sourceTrackId` (at most 200 UTF-8
bytes). Microphone and system sources omit it. The Library preserves this identity
separately from each span's unique ID and filename. Writing down groups repeated
browser source IDs into one unnamed speaker, even when labels change. Simple IDs
retain their existing `track-…` spelling; opaque values that cannot be a valid bounded
speaker ID use a deterministic SHA-256 spelling. Labels never establish identity.
Me, The others and received plain-audio speaker rules remain unchanged.

Both CC0 fixtures and the sparse-WAV generator are copied unchanged from coordination
commit `3349555b8e9bd5f47236cc5ce61b1edfee201d34`. Tests exercise both the actual
RecordingLoader and LibraryScanner, compare their timeline projection with the
handwritten expectations, and verify that reading leaves files unchanged. A focused
pipeline test uses the real pinned Silero segmentation and deterministic recognition
to check source-to-speaker routing across two spans; existing goldens still test the
real speech engines.

The build-only `cassini-session-transition-probe` pauses at each persistence boundary.
Its XCTest parent sends SIGKILL to that exact private child and reopens the folder.
Before metadata publication, the previous manifest is byte-identical; afterward,
the new fallback event and system track are both present. The test covers four
boundaries and real process death, not power loss. The probe accepts only a generated
private test root, has a 10-second watchdog, opens no capture device or UI, and is
never embedded in Cassini.app. The checkpoint observer is a testing SPI with no
native-messaging or app-setting entry point.
