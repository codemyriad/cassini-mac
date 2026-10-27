# M5 proposal: one export contract for Mac and GNOME

**For Silvio's decision; design only.** GNOME and Mac should review this same note before
implementation. The coordination copy is EXPORT-DESIGN-M5.md; responses belong in the agents'
STATUS files so the proposal does not fork. The raw WAV/session folder remains the capture
record. Export creates a new file and never deletes or rewrites those sources automatically.

**Which audio is “the recording”?** Recommend one ordinary stereo, 48 kHz Ogg Opus master.
Use the chosen WebRTC sources, or the chosen tab/system/application mix plus microphone when
present in that session. Avoid including both a mixed output and the individual remote tracks
it already contains. Present source selection before export; track labels alone cannot prove
that two tracks are duplicates or different people. Retain individual WAVs for reprocessing.
Multichannel/per-participant archival audio is a later option, not the default portable file.

**One deterministic timeline.** Validate safe paths and authoritative complete WAV frames.
Resample each selected source to 48 kHz, place frame zero at its startOffsetMs, preserve gaps
as silence, and end at the latest source end. Keep the session origin (including leading
silence) so transcript times remain comparable. Unknown recovered offsets require explicit
alignment or single-track export. Native clock drift is not silently corrected from arrival
times. Mono sources go equally to L/R; stereo sources retain L/R. Sum in float, then apply one
fixed attenuation only if needed to keep the final peak <=0.95; do not amplify quiet/noisy
sources or change gain as speakers change. Record selection, resampling and gain in provenance.

**Encode and pack once.** Proposed common preset: Opus stereo, 48 kHz, 20 ms packets, VBR
96 kbit/s. Pin encoder/settings in both implementations and test decoded duration/timeline;
byte identity across platforms is not a requirement unless Silvio requests one shared encoder.
Account for pre-skip/final granule trimming. The portable file's audio is this master; its
sampleCount/duration and exact-opus-audio-v1 digest come from the actual encoded stream.
Reuse the Cassini v1 packing rules/reference conformance suite; write to a temporary file,
validate it with both readers, then rename. Failure leaves the original folder intact.

**Transcript hook.** First offer plain audio .opus when no timed transcript is available.
“Export Cassini with transcript” requires a valid cassini.words.v1 payload and manifest; do
not fabricate words or participant identities to fill metadata. A later transcription action
can operate on separate sources for recognition quality and map each word by source offset
onto the master timeline, checking the final playable sample range. Speaker IDs come from
reviewed attribution/diarization, not browser track IDs or DOM names (Meet slots may switch).
Keep model/provider, language, timing method, attribution uncertainty and processing history
in provenance. Cloud transcription would be an explicit product choice; export itself is
local. Attaching/revising transcript tags can retain the encoded audio packets and digest.

**Decisions requested:** (1) Approve stereo master + retained source folder as the default?
(2) Approve the mix/gain/96-kbit preset, or require a shared encoder for byte-identical audio?
(3) Approve plain-audio export first, then a separate timed-transcript/Cassini packing action?
After agreement, both apps implement the same source-selection/timeline fixture (staggered
start, overlap, silence/drop gap, interrupted tail) and cross-read each other's exported files.

Format basis: https://format.gocassini.com/ (Cassini v1, cassini.words.v1 and
exact-opus-audio-v1); this note proposes application behavior and does not amend that format.
