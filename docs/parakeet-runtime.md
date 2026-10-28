<!-- SPDX-License-Identifier: GPL-3.0-or-later -->
# Parakeet Ultra runtime and parity (D16)

The runtime uses codemyriad sherpa-onnx `v1.13.7-cassini.8`, source
`0c2ee3f3f5f16bb06d234a0f98632810296ba0eb`, with the Mac binaries at
`e46ea026d083a5319cca8c7f2ee4a8f32019fed7`. `Parakeet/pins.json` is the
coordinator's verbatim engine pin. `Parakeet/UPSTREAM.json` additionally binds the
fork's exact C header and the matching Apache-2.0/MIT/third-party notices. The
header stays unmodified. No upstream 2.x header or C++ wrapper is used.

`scripts/fetch-parakeet-runtime.py --output DIRECTORY` checks both original
architecture slices and assembles universal libraries. Original names/install
names and slice bytes remain intact, so the standalone checker can compare
source hashes. Bundled copies will be re-signed and checked under the app's seal.
Neither importing the Swift module nor constructing an asset capability loads an
engine. The C bridge checks the live telemetry environment before dlopen and
checks the exact fork and ORT versions before constructing a recognizer.

`swift run cassini-model-fetch --output APP_DATA_DIRECTORY` is a build/test-only
tool, excluded from the app bundle. It invokes the shared D4 installer with the
D16 `(id,source_sha256)` and uses the four downloaded files unchanged. The model
is optional app data; it is never a bundled resource. Runtime requests are made
only by the future Download action, and never by opening Settings or About.

The recognizer uses the D16 zero-initialized C config, 16 kHz/128 features,
CPU/two threads, greedy decoding and a new stream per segment. Token float32
values are promoted to double before half-away-from-zero rounding. All Unicode
L*/N* categories count toward word ends; punctuation and combining marks do not
extend them. Output language is `und`; segment text is only trimmed at its ends.

The shared Parakeet goldens are copied verbatim into
`Tests/CassiniParakeetTests/Goldens`, including their SHA256SUMS. The tests use the
existing D11 FIR/Silero/SpeechGate implementation and its input fixtures, compare
every segment range and input hash before decoding, require 66 words per golden,
and then apply only D16's trailing ASCII punctuation and 80 ms time tolerances.
The worker and Settings integration must retain these checks on ARM and Intel.

Local parity command (paths refer to private build assets):

```
ORT_DISABLE_TELEMETRY=1 NEEDLE_TELEMETRY=0 DO_NOT_TRACK=1 \
CASSINI_PARAKEET_RUNTIME=/tmp/cassini-parakeet-assets/runtime-original \
CASSINI_PARAKEET_MODEL=/tmp/cassini-parakeet-model-data/models/parakeet-ultra-0.6b-int8/18cb623004dd6c15999b93cb70b14d8a1f6e8f3a2a97ff733f104bfc3494f6a9 \
CASSINI_PIPELINE_ASSETS=/tmp/cassini-wave3-pipeline-assets \
swift test --jobs 2 --filter 'ParakeetTests|ParakeetGoldenTests'
```

This checkpoint establishes the local M4 runtime/word conversion. The app-side
model selection, worker lifetime, removal/fallback, provenance and hosted Intel
validation are subsequent work, not claimed complete here. No user Library,
preferences, desktop, microphone or system-audio devices are used by these tests.
