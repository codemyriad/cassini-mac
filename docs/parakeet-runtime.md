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
only by the explicit Download action, and never by opening Settings or About.

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

The hosted Parakeet area runs both goldens and the production worker/app probes
on native ARM and Intel runners. Local parity establishes the M4 result only;
the Intel execution and hosted UI gates must pass before merge. The private
probes do not use the user Library, preferences or capture devices.

The production `cassini-parakeet-worker` serves one meeting request and exits. It
uses the same bounded subprocess I/O and parent-death watchdog policy as Whistle.
A malformed installed model returns `invalid-model` before changing a meeting,
so the app can fall back without misclassifying a native-runtime failure.
`ParakeetModelLease` holds private hard links under a kernel-leased speech work
folder; removing the installed revision cannot retire an accepted job's inputs.
Use an app-data job root on the model's volume. Cleanup reclaims abandoned links
after a killed parent without relying on a reusable PID.

`SignedSpeechBundle` verifies the actual executing helper and the app seal once,
then supplies immutable capabilities to its recognizer and VAD. Standalone tools
accept only original source-pinned libraries. Silero and ORT1.23.2 stay unchanged;
Parakeet's private ORT1.28.1 is loaded locally in the separate Parakeet process.

Transcription records `transcript.model` using the D16 schema. A resumed job
retains partial words only from the same known model. Another/unknown model
regenerates them, preserving notes, names and audio. Parakeet always writes `und`;
Whistle preserves its detected language when resuming the same recognizer. The
existing Whistle tail-retention fixture now explicitly names its known model.

`scripts/test-parakeet-worker.py` exercises real offline Opus transcription, model
provenance, unchanged audio, received Speaker1, pre-dlopen source/privacy rejection,
distinct invalid-model results and owner death with stdin still open. It uses
private generated meeting folders, never capture devices.

Settings keeps Whistle selected by default. Downloading Parakeet does not select
it; the person chooses the installed model explicitly. Each transcription job
accepts its model when it starts. Remove immediately selects Whistle for the
next job while an accepted Parakeet job keeps its leased files. A failed startup
hash check retires the corrupt installation, persists the Whistle choice and
retries that job with Whistle before writing any transcript words. Runtime or
recognition failures remain distinct from an invalid model.

The app and both inherited-sandbox speech workers have no network-client
entitlement. Only the separate `CassiniModelDownloads.xpc` service has it. An
explicit Download passes an implicit security-scoped bookmark for the model
data directory; the service validates the resolved directory against the
requested canonical directory and holds its access until the operation ends.
The model pin and allowed HTTPS origin are fixed in the service. Cancellation
waits for service cleanup before releasing ownership. Progress marks installation
complete only after hash checks and atomic publication.

The hosted build produces the app and test bundles once per architecture, with
Xcode 16.4. Parakeet fixtures use a separate artifact; the existing clean-machine
Whistle job still receives no optional model or separate compiler/model cache.
CI validates the exact product profiles for the app, workers and service and
checks both Debug and Release bundles for pinned notices/runtime metadata and
absence of optional weights. The download/worker network probe and real app
queue probe use fresh private data; they do not grant device permissions.
