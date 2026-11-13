# WP6: Name a speaker (L-14, L-41, L-46)

The existing native sheet remains responsible for modality, window-wide scrim,
keyboard isolation, dismissal and focus restoration. Hosted before evidence
already shows a centered floating sheet. The speaker dialog now uses 12-point
corners, the shared raised surface, a speaker heading in ink, talk time, a real
bounded quote with a left bar, and a vertical Name field with initial focus and
the shared accent border. Merge into is on the left of the single footer;
Cancel and Save name stay on the right. The existing sample action stays available.

The quote comes from the actual sampled speaker turn. Chronological ordering and
equal-time input order are preserved, other speakers and out-of-range words are
excluded, and display is bounded to 240 graphemes without splitting emoji. Quote
preparation runs off MainActor alongside the existing talk-time and sample facts.
It adds no stored metadata and changes no transcript text, timestamps or audio.

The existing coordinator still owns validation, naming, clearing, merge/undo,
retry, writer serialization, move/Trash guards and shutdown. Sample playback
stops on dismissal. No new persistence, file format or saved-voice backend is
introduced. Saved voices, match notices, Remember this voice and its switch are
omitted because the Mac has no backend for them (phase1-brief Rule 4); the PR
must call this out explicitly.

Proof extends the real naming/clear/merge/undo/reopen UI case: quote and heading,
initial keyboard focus, footer placement, native sheet modality and a light/dark
speaker-editor capture. Exporter and independent PR-shots inventories require
34 paired boards. The dark lane includes this native writer case and retains a
12-minute outer hang bound. Targeted SpeakerEditsTests include real file edits
and the quote ordering/Unicode boundaries. Local app/UI build-for-testing is
allowed; actual app execution/screenshots remain hosted-only.

Stacked locally on WP5 while WP1 is pending. Publish packages in the requested
WP3, WP4, WP5, WP6 order with main bases and Seat: big-mac. Final exact-head CI
and actual light/dark screenshot proof are required before readiness.
