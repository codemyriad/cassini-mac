# S-8a: bundled Whistle spike

The app build fetches only the pinned Needle 3.3.0 wheels and Whistle weights from
DECISIONS-UX D5. Whistle/pins.json records wheel, extracted dylib and model SHA256;
corrupt cached or downloaded data fails the build. Both macOS engine slices are
combined into a universal dylib. The build signs it and the sandbox-inheriting
worker, and records final shipped checksums separately from unsigned source pins.
Whistle is bundled inside the app; no runtime download code is present.

The Swift C-API wrapper uses dlopen only in cassini-whistle-worker. Privacy values
NEEDLE_TELEMETRY=0, DO_NOT_TRACK=1 and ORT_DISABLE_TELEMETRY=1 must be set before the
library loads. Both worker entry point and wrapper enforce this. A constructor
sentinel regression proves that omitting any setting prevents all library code
from loading; a safe invocation proves the sentinel really exercises dlopen.

One child loads one model and serves sequential JSON-line requests over pipes.
Requests contain a local WAV path; responses contain the id and transcript or a
structured error. This is private spike IPC, not a change to either shared browser
protocol. For the spike, input is limited to 30 seconds of mono PCM16 at 16 kHz.
There is no queue, resampling pipeline or transcription UI yet: UX13 owns those.
The C API's model state is process-global and is never used concurrently.

## Proof and limits

- `swift test --filter WhistlePrivacyTests`: unsafe environment overrides and
  unchanged shared JFK fixture hashes.
- `scripts/fetch-whistle.py --output build/Whistle`: build-time fetch and pins.
- `scripts/test-whistle-worker.py --worker .build/debug/cassini-whistle-worker
  --bundle build/Whistle --report build/whistle.json`: constructor guard and two
  identical transcriptions in one child, entirely offline after artifact fetch.
- `scripts/check-whistle-bundle.py APP`: shipped checksums, signatures, licences
  and both engine slices, without launching the app.
- Hosted-only Debug `--whistle-self-test`: the signed sandboxed app starts the
  bundled inheriting helper and makes two JFK requests. It checks the words and
  exits. It cannot run without explicit GitHub-hosted environment guards. The
  sample WAV/text are copied only into Debug bundles, never the Release app.
- `Whistle bundling spike` CI runs native arm64 and Intel workers and a universal
  app build plus the sandboxed-parent/helper check. No audio device is opened.

The first arm64 result is:

> And so, my fellow Americans, ask not what your country can do for you, ask what you can do for your country.

The shared jfk.txt has `you. Ask` where the engine emits `you, ask`. Exact string
match is false; the sequence of case-folded words is identical. Tests report both
facts and retain the shared reference verbatim. GNOME output must be compared
when available; this spike does not redefine the cross-app golden.

The initial local C-API file probe took about 0.12 s including load on DrMeyers;
this is a smoke-test observation, not a performance benchmark. No local app,
desktop, browser or audio-device test was run. UX13 still needs the app queue,
long-meeting chunking, cancellation/crash recovery and real progress reporting.
Apache-2.0 LICENSE and NOTICE are included with the bundle.

## Post-merge I/O fixes

The packaging exchange runs all blocking work off the main actor, drains stdout
and stderr concurrently, caps retained diagnostics while continuing to drain, and
has an independent timeout/cancellation path. Pipe writes suppress SIGPIPE only
on their own descriptor and return EPIPE; no Objective-C writeData exception is
used. The worker rejects oversized lines during buffering, and WAV/model files
are checked with O_NOFOLLOW/O_NONBLOCK/fstat before bounded reads.

Regressions cover an early child exit, closed stdout, noisy stderr beyond pipe
capacity, a child ignoring SIGTERM, cancellation, oversized lines/files, symlinks
and FIFOs. Actual worker requests verify it can reject invalid inputs and still
serve the next valid JFK request. Library/model identity verification and bundle
layout are addressed separately from these stream/input bounds.

## Bundle layout and artifact-cache recovery

Only the executable copies in Contents/MacOS ship. The engine is in
Contents/Frameworks; weights/licences/pins/checksums remain in Resources/Whistle.
The checker rejects obsolete resource copies, including leftovers from an
incremental build. This follows Apple's bundle layout guidance:
https://developer.apple.com/documentation/bundleresources/placing-content-in-a-bundle
Signing requests a secure timestamp for certificate identities; ad-hoc builds use
no timestamp. Developer ID notarization is a later distribution check.

A corrupt cached archive is removed and fetched again. HTTP success with bad or
truncated bytes is retried just like a connection failure; every attempt is
hashed before publication. Unique temporary files are removed on every failure
and atomically renamed only after verification. Hermetic tests cover valid cache,
corrupt cache, a truncated response followed by good data, and repeated invalid
responses followed by recovery on the next build.
