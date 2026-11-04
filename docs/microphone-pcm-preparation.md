# Microphone PCM preparation (D46)

D46 supersedes transcript-level echo classification. Cassini currently passes
unfiltered stored audio to its existing transcription pipeline and publishes
every recognized word. Existing unknown `echo` fields are ignored when reading;
scanning does not rewrite stored transcripts. UI, shares, search and exports
keep those words. No legacy cleanup or re-transcription is scheduled.

D46.2 parks AEC and removes D46.1 from the queue. The shared spike and its
vectors remain a plan for possible later work; no further spike, fixtures,
hardware tests or implementation are scheduled. Stored source audio remains
unchanged. No new PCM filtering is implemented by the revert.

Reusable components retained from D38 are the original clean/bleed/room PCM
fixtures, their recorded hashes, bounded raw-mono window RMS measurements, and
`TranscriptionSourceKinds`: microphone/local versus
system/application/remote/media/tab references. The retained PCM-level fixture
contains only numerical measurement inputs/outputs; the retired transcript
matching rules and scorer are removed. FIR/VAD/Whistle/DC goldens and the
independent automatic-name/quote work are unchanged.
