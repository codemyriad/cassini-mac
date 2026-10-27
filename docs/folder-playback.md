# Meeting folder playback (UX-play)

The Library preview plays a saved Recording-* folder as one AVMutableComposition.
Each validated WAV gets its own audio track at the original session.json
startOffsetMs. AVFoundation mixes concurrent sources and converts differing sample
rates. Fractional offsets retain a nanosecond time base. The original files and
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
