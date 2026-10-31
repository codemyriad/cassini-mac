# Microphone echo (D38.1–D38.3)

After recognition, Cassini flags microphone words that repeat another physical
source. Audio, word text, timestamps and speaker identities stay intact in the
saved transcript. Only `echo: true` is serialized; older v1 readers can ignore it.
Turns, quotes, speaking shares, search, Markdown and Cassini exports omit flagged
words. There is no setting or change to capture or recognition input.

The classifier retains physical source indices even when two tracks share a
speaker. It compares NFKC/full-case-folded words with edge Unicode punctuation
removed, an inclusive 0–600 ms lag, and a microphone level at least 6 dB quieter.
Unmatched words need direct anchors on the same microphone less than 1000 ms
apart and the same level protection against another source's surrounding window.
Sandwich flags never become anchors. Missing level measurements preserve words.
Levels come from the existing raw mono scratch file, before the VAD-only filter,
with source offsets applied and bounded reads. Repeated words use indexed range
maxima rather than a quadratic all-pairs comparison.

Resume retains flags on untouched saved tails and recomputes newly recognized
words. Retry regenerates the transcript. A shared speaker never joins the
physical microphone tracks for classification. A received single audio file has
no separate microphone source and is unchanged.

## Frozen fixtures and checks

`Tests/CassiniTranscriptionTests/Fixtures/Echo/UPSTREAM.json` pins the shared
20-case/311-word vector and the three synthetic clean/bleed/room recordings from
`cassini-coordination/ux-draft/bleed`. The vector SHA256 is
`81805038e849a856783bd51c5965735f4d3f1246ac31eeb584050b7940365ad2`.
These are generated voices, with no captured meeting or personal recording.
Tests check all vector flags, 422 frozen word/window RMS measurements, source
boundaries, resume, raw JSON compatibility, search cache invalidation and exports.

The hosted ARM and Intel Whistle jobs also run the real pipeline on all three
recordings and upload raw transcripts, filtered transcripts and metrics under
`build/pipeline`. Run the same offline file check locally with pinned assets:

```sh
CASSINI_PIPELINE_ASSETS="$PWD/build/Whistle" \
CASSINI_PIPELINE_REPORT_DIR="$PWD/build/pipeline" \
swift test --filter EchoPipelineTests
python3 scripts/check-microphone-echo.py build/pipeline
```

The scorer uses the shared `measure.py` truth convention: clean-source 10 ms
peak windows above 300 PCM units, 500 ms silence gaps and a 500 ms word tail.
Each fixture must have at most two echo words left, at most ten displayed turns,
and zero genuine microphone words suppressed. The clean control must have no
flagged words. For Mac QA's unchanged shared `measure.py`, select the generated
`echo-clean-visible.json`, `echo-bleed-visible.json` or `echo-room-visible.json`;
the raw reports deliberately retain echo words. No audio device is opened.
