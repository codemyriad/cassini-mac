# Meeting folder playback (UX-play)

The Library preview plays a saved Recording-* folder as one AVMutableComposition.
Each validated WAV gets its own audio track at the original session.json
startOffsetMs. AVFoundation mixes concurrent sources and converts differing sample
rates. Each track starts at its D55 placement frame, startOffsetMs · rate / 1000
rounded half away from zero at the track's own rate (`TrackPlacement`), the same
placement recognition (16 kHz) and the export mix (48 kHz) use; an unknown offset
is refused (D19). The original files and
metadata remain read-only; no merged temporary audio file is required.

Play toggles to Pause (shared catalog player.pause). Selection changes and Library
closure cancel any pending load and release playback/observers. End-of-file resets
the button to Play and rewinds. Existing portable .opus playback still uses the
frame-based legacy player, unchanged.

Only saved sessions with validated timing can play. Recording/Saving sessions stay
disabled. A missing/invalid start offset is retained as nil and prevents session
Play: the display-only zero fallback in LIBRARY D3 is never used for alignment.
Readable Library rows and their transcripts remain available. A later recovery
surface may offer explicit single-source playback when timing is unknown.
System error presentation is retained until UX3 defines playback error copy.

## Verification

`swift test --filter SessionCompositionTests` uses AVAssetReaderAudioMixOutput,
not AVPlayer or an audio engine. It opens no audio device. It verifies summed
samples at overlaps, a silence gap, a fractional offset, differing sample rates,
a nonzero seek range, and rejection of invalid/unknown timing. It also generates
the pinned shared main fixture and builds Budget review through the production
Library scanner; duration, source count and the mixed opening tone are checked.
The regular hosted CI runs these tests with the complete package suite.

The hosted Library board test additionally requires the Budget preview Play
button to be enabled. No user desktop, browser or hardware audio tests are used.
The redesigned Meeting player, transport shortcuts and media keys are UX3 work.

## Recovery WAVs and empty tracks

The scanner exposes physical frame counts separately from display metadata.
Empty tracks do not enable Play alone or block another non-empty source. For a
canonical recorder WAV whose header sizes lag physical complete frames, playback
creates an owned temporary copy with corrected sizes and trims incomplete frames.
The source WAV and session metadata are never changed. The retained SessionTimeline
owns that storage until the player releases it, including cancellation/error paths.

Offline regressions reproduce zero/stale data headers and verify full decoded
audio duration/samples, source-byte preservation, scratch cleanup and mixed empty /
nonempty tracks. Unknown source offsets are still never fabricated as zero.
Composition failures use the system's localized file-read error presentation.

## Transport lifetime

Requested playback is separate from asynchronous AVPlayer state. Pause remains
available when a scan changes eligibility. Source, selection and offline changes
cancel preparation and close the player. Playback failures return to Play and use
the system error presenter. EOF waits for an exact rewind before a queued replay;
Pause or teardown invalidates that request. Starting recording or legacy playback
stops the preview, and preview playback pauses the legacy player.

`SessionPlaybackTests` exercises those transitions with an injected transport,
including stale callbacks and cancellation, without creating an audio device.
