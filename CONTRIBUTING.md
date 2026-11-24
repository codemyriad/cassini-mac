# Contributing to Cassini for Mac

This document covers building, testing, repository layout, shared UX contracts, protocol pinning, and release packaging for developers and maintainers working on `codemyriad/cassini-mac`. See [`docs/README.md`](docs/README.md) for architecture and operations notes, [`AGENTS.md`](AGENTS.md) for agent workflow entrypoints, and [`release-notes.d/README.md`](release-notes.d/README.md) for user-facing release note fragments.

## Building

```sh
brew install xcodegen
xcodegen generate
xcodebuild -project Cassini.xcodeproj -scheme Cassini -configuration Debug -derivedDataPath build build
open build/Build/Products/Debug/Cassini.app
```

Requires macOS 15+ and Xcode 16+. The app is sandboxed and ad-hoc signed for local runs. To open a sample `.opus` file directly, pass its path to `open build/Build/Products/Debug/Cassini.app path/to/meeting.opus` (for example one of the conformance fixtures in `Tests/CassiniKitTests/Conformance/opus/`).

## Layout

### App, extensions, and shared UI components
- `Cassini/` — the macOS SwiftUI app (split-pane Library, meeting view with TextKit 2 transcript and `AVAudioEngine` playback, Recording page, Search, Settings, and Saved voices).
- `Components/` — Saturn UI components wired into the app target (`StatusBadge`, `BadgeLabels`, `MeetingCard`).
- `QuickLook/` — the Quick Look preview extension for `.opus` meeting files.
- `BrowserSetup/` — sandboxed XPC service and helper for per-user browser companion registration.
- `BrowserExtension/` — vendored Chromium extension (early WebRTC hooks, tab capture fallback, worklet, and Playwright integration tests).

### Swift packages (`Sources/` and `Tests/`)
- `Sources/CassiniKit` — portable `.opus` format reader (Ogg pages, OpusTags, chunk sets, manifest, `cassini.words.v1`, `exact-opus-audio-v1` audio digest), turn/timeline model, and transcript utilities.
- `Sources/CassiniLibrary` and `Sources/CassiniLibraryWatchers` — `Music/Cassini` Library scanner, meeting state/badge derivation, speaker metadata, and debounced FSEvents watcher.
- `Sources/CassiniPlayback` — aligned multi-track `AVMutableComposition` playback for saved `Recording-*` folders.
- `Sources/CassiniRecording` — incremental WAV sessions, Core Audio process tap capture, and portable browser/native protocol.
- `Sources/CassiniBrowserControl` and `Sources/CassiniBrowserSetup` — browser call lifecycle control and companion registration.
- `Sources/CassiniTranscription` — transcription queue, segment cache, live head-start precomputation, and speaker alignment.
- `Sources/CassiniWhistle` and `Sources/cassini-whistle-worker` — privacy-guarded subprocess wrapper around the bundled Whistle speech model and Needle 3.3.0 inference engine.
- `Sources/CassiniParakeet`, `Sources/CassiniSherpaBridge`, and `Sources/cassini-parakeet-worker` — optional Parakeet Ultra runtime and worker subprocess.
- `Sources/CassiniModels` and `Sources/cassini-model-fetch` — offline-verified model downloader and manifest verification.
- `Sources/CassiniExport`, `Sources/CassiniOpus`, and `Sources/CassiniZstd` — portable `.opus` and Markdown export, Opus encoding, and Zstandard support.
- `Sources/CassiniSearch` — local full-text search index over Library transcripts.
- `Sources/CassiniSpectrogram` and `Sources/CassiniVAD` — live recording spectrogram and voice activity detection.
- `Sources/cassini-browser-host`, `Sources/cassini-control-host`, and `Sources/cassini-inspect` — local Chromium Native Messaging hosts and conformance inspection CLI.
- `Tests/` — Swift test suites covering every package above, plus vendored CC0 format conformance vectors and shared `cassini-ux` test vectors.
- `UITests/` — XCUITest suites including `LibraryBoards`, `WindowlessApp`, `LocalCompanionInstall`, `SpectrogramMotion`, and `WindowScreenshots`.

### Docs, tooling, and vendored pins
- `docs/` — architecture, protocol, CI, and release documentation (indexed in [`docs/README.md`](docs/README.md)).
- `scripts/` — build, packaging, UX contract verification, screenshot export, and CI contract test scripts.
- `Spikes/` — isolated measurement and verification probes compiled by SwiftPM and CI (`Spectrogram`, `BrowserSetup`, `BrowserConnect`, `SessionTransitions`, etc.).
- `release-notes.d/` — curated user-facing release note fragments (see [`release-notes.d/README.md`](release-notes.d/README.md)).
- `Whistle/`, `Parakeet/`, `Opus/`, `ModelDownloads/`, `Artwork/`, `Distribution/` — pinned runtime/model manifests, licenses, artwork, and installer assets.

## Implementation notes

- Playback of portable `.opus` files uses `AVAudioEngine` + `AVAudioFile`, not `AVPlayer`: CoreMedia's Ogg demuxer seeks by byte estimate and lands up to two seconds away from the time it reports, and its duration is an estimate. `AVAudioFile` decodes Ogg Opus frame-exactly (its `length` equals the spec's playable sample count), so the word highlight follows what is actually heard.
- Saved `Recording-*` folders in the Library play through `AVMutableComposition` (`Sources/CassiniPlayback/SessionComposition.swift`), placing each validated WAV on its `startOffsetMs` timeline without rewriting source files.
- The `.opus` reader is a `full`-profile consumer: it verifies the audio digest on open and ends in one of the spec's six trust states.
- Native capture uses Core Audio process taps (`AudioProcessTap`) and `AVAudioEngine`. Browser helpers can be shared across tabs, so a selected process may include several tabs. System capture includes other apps and notifications. An independently captured microphone also records while the meeting app is muted.
- Recording sessions contain PCM WAV files plus `session.json` with source labels and timing offsets. Partial recordings are preserved on disconnect; source/device format changes stop with an explanation. Recordings are transcribed offline (with Whistle or Parakeet Ultra) and can be exported to portable Cassini `.opus` files or Markdown.
- Native continuity uses the first host timestamp plus sample counts; later device-clock drift is diagnostic. Each source has ten seconds of bounded writer buffering. Overflow becomes counted silence and an interrupted result. Multichannel microphone input records channels 1 and 2, with a visible notice.
- Opening a recording tolerates fractional GNOME timestamps and reads authoritative WAV frame counts. Damaged or missing metadata can be recovered read-only; unknown labels and relative start times are explicitly reported. Metadata is synced before atomic replacement.

### Developer browser-host registration

From a git checkout, after loading `BrowserExtension` as an unpacked extension in `chrome://extensions`:

```sh
scripts/install-browser-host.sh YOUR_EXTENSION_ID
```

This developer command builds and ad-hoc signs the local host and registers it only in existing Chrome, Chromium, Edge, and Brave user directories. Alternatively, pass `/path/to/Cassini.app` as a second argument to register its bundled signed host without a Swift build. Rerun after moving the app or changing the extension ID. `scripts/install-browser-host.sh --uninstall` removes registrations while retaining the app, helper, and recordings.

The browser/native interface is documented in [the portable v1 protocol](docs/browser-recording-protocol.md) for reuse by the GNOME recorder.

## Test tiers and CI resources

See [the D-1064 audit](docs/ci-optimization-d1064.md) and [`docs/ci/build-once.md`](docs/ci/build-once.md) for fast local checks, asset-backed/GUI tiers, shared iOS/Mac runner locking, and workspace cleanup.

## Recording and contract tests

```sh
swift test
node --test BrowserExtension/tests/*.test.cjs
python3 browser-protocol/conformance/run.py .build/debug/cassini-browser-host
python3 browser-protocol/verify.py --pinned BrowserExtension
python3 scripts/test-ci-contract.py
```

Real Chromium tests (generated audio only; failure artifacts are retained under `BrowserExtension/tests/artifacts`):

```sh
swift build
npm ci --prefix BrowserExtension/tests
BrowserExtension/tests/node_modules/.bin/playwright install chromium
node BrowserExtension/tests/synthetic-capture.mjs
node BrowserExtension/tests/extension-capture.mjs
node BrowserExtension/tests/tab-capture.mjs
```

Playwright is pinned to 1.61.1 / Chromium 149. Tests use temporary browser profiles; a brief generated tone may be audible. `CASSINI_NATIVE_HOST` can select another executable host for Linux compatibility tests, and `PLAYWRIGHT_MODULE` may select a different installed Playwright for compatibility diagnostics.

Native audio checks (Debug build only):

```sh
scripts/check-native-recording.sh --sink-only # no microphone or system-audio permission
scripts/check-native-recording.sh             # actual Core Audio tap; macOS consent needed
```

Both check stereo separation with generated 440/880 Hz tones. The sink-only check covers planar and interleaved input, frame counts, and the production WAV writer. The full check captures only Cassini's own generated tone, launches through LaunchServices so macOS attributes consent to Cassini, and never opens the microphone.

## Shared UX contracts

Shared contracts, brand tokens, UI strings, and test vectors live in [`codemyriad/cassini-ux`](https://github.com/codemyriad/cassini-ux). Never edit vendored copies locally — update `cassini-ux` first, then sync and re-pin here.

After fetching `cassini-ux`, run:

```sh
python3 scripts/sync-ux.py /path/to/cassini-ux
python3 scripts/check-ux-copy.py
python3 scripts/check-brand-tokens.py
python3 scripts/check-badge-labels-pin.py
```

`scripts/sync-ux.py` vendors `origin/main` strings and import types verbatim, updates both commit/hash pins, and verifies copy policy.

## Conformance

```sh
swift build
cd Tests/CassiniKitTests/Conformance
python3 run-conformance.py --adapter ../../../.build/debug/cassini-inspect --profile full
```

### Native recording in CI

The `native` job in `.github/workflows/ci.yml` runs the generated-PCM sink check against the Debug app built once per push, covering planar and interleaved input, frame counts, stereo 440/880 Hz separation, and the production WAV writer without microphone or system-audio permission. The native session and writer Swift tests run in the `kit` job's full `swift test`.

The actual Core Audio process tap and real `tabCapture` require macOS system-audio consent and a working output device, which headless runners do not have. They are manual checks on a developer Mac: `python3 scripts/run-native-ci.py --mode full` (or `scripts/check-native-recording.sh`) and `node BrowserExtension/tests/tab-capture.mjs`. Consent or output-device timeouts produce `status: "blocked"` in `result.json` and exit nonzero so an unavailable hardware gate cannot be mistaken for a passing code test.

### Shared protocol ownership and product checks

The canonical repository is <https://github.com/codemyriad/cassini-browser-protocol>. Protocol, extension, schema, and fixture changes are committed and pushed there first. This app records its exact upstream revision in `browser-protocol/PINNED_COMMIT`; the offline verifier checks the Git commit/tree as well as file checksums and the installed extension. To update, run the upstream `vendor.py COMMIT /path/to/cassini-mac/browser-protocol /path/to/cassini-mac/BrowserExtension`.

SPEC v1.1 keeps wire version 1. Both native recorders use the same session folder contract; Mac writes `source: "macos"`, GNOME writes `"gnome"`, with one WAV per microphone/system/application source.

## Releases and packaging

### Developer ID DMG releases

User-facing releases are Developer ID signed and notarized DMGs produced by `scripts/release.py` and `scripts/publish-release.py` (see [`docs/developer-id-release.md`](docs/developer-id-release.md) and [`docs/release-notes.md`](docs/release-notes.md)).

### Ad-hoc zip packaging for local/manual verification

To package an ad-hoc build for local verification:

```sh
xcodegen generate
xcodebuild -project Cassini.xcodeproj -scheme Cassini -configuration Release -derivedDataPath build build
python3 scripts/package-release.py build/Build/Products/Release/Cassini.app build/Cassini-recording.zip
sudo python3 scripts/check-release-install.py build/Cassini-recording.zip --report /tmp/cassini-release-install.json
```

See [`docs/native-audio-manual-check.md`](docs/native-audio-manual-check.md) for the consent-dependent hardware recording manual check.
