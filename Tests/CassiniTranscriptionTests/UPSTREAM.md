Shared D11/D26.1 goldens and SHA256SUMS are copied verbatim from
cassini-coordination/ux-draft/whistle at coordination commit 7e7000f. The approved
Silero-only high-pass changes the first pipeline segment start 14336 to 13824;
raw WAVs, the FIR output and recogniser input remain unchanged. Segments, text,
word counts and segment input SHA256 remain exact; D11.3 permits 80 ms word-time
movement only after input hashes match. JFK audio is public-domain US federal
government material.

whistle-text-exceptions.json SHA256
448aeaeaae178621e3296bc9cdc0463172bbdc35525aed74becdef31541c0b56
permits only as/ask at word 37 / segment 5 under its exact audio/golden/engine pins.
D26.1 rebinds only the approved golden digest; the allowed text/range and input
hash are unchanged. Production recogniser output is never rewritten.

Fixtures/DC contains the two unmodified public synthetic D26.1 WAVs and the
spec from coordination commit 196c179. Tests cover asserts a-e, whole-frame-only input
hashes, state/reset, raw recognition scratch and continuous AC peak metering.
No personal recording is used.

Fixtures/jfk-received.opus is a plain Opus derivative of the public JFK fixture,
made without capture: ffmpeg -i Goldens/jfk.wav -ac 1 -ar 48000 -c:a libopus
-b:a 32k -application audio Fixtures/jfk-received.opus. It exercises Received
import, offline Opus decode, the production pipeline and Speaker 1.
