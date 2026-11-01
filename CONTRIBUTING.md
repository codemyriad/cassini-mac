# Contributing to Cassini for Mac

This document covers building, testing, architecture, protocol pinning, and release packaging for developers and maintainers working on `codemyriad/cassini-mac`. See [`docs/`](docs/) for design and milestone notes.

## Building

```sh
brew install xcodegen
xcodegen generate
xcodebuild -project Cassini.xcodeproj -scheme Cassini -configuration Debug -derivedDataPath build build
open build/Build/Products/Debug/Cassini.app Samples/your-meeting.opus
```

Requires macOS 15 and Xcode 16. The app is sandboxed and ad-hoc signed for local runs.

## Layout

- `Sources/CassiniKit` — the format reader (Ogg pages, OpusTags, chunk sets, manifest, `cassini.words.v1`, the `exact-opus-audio-v1` audio digest), the turn/timeline model and transcript export. No dependencies beyond Foundation, CryptoKit and zlib.
- `Sources/CassiniLibrary` and `Sources/CassiniLibraryWatchers` — read-only `Music/Cassini` Library scanner, meeting state/badge derivation, and debounced FSEvents watcher.
- `Sources/CassiniPlayback` — aligned multi-track `AVMutableComposition` playback for saved `Recording-*` folders.
- `Sources/CassiniWhistle` and `Sources/cassini-whistle-worker` — privacy-guarded subprocess wrapper around the bundled Whistle speech model and Needle 3.3.0 inference engine.
- `Sources/CassiniRecording` — incremental WAV sessions and portable browser/native protocol.
- `Sources/cassini-browser-host` — local Chromium Native Messaging host.
- `BrowserExtension` — early WebRTC hooks, tab capture fallback, worklet and integration tests.
- `Sources/cassini-inspect` — a CLI that prints a conformance-suite observation for a file (`--summary` for a readable report, `--metadata` to skip the audio check).
- `Tests/` — Swift test suites (`CassiniKitTests`, `CassiniLibraryTests`, `CassiniPlaybackTests`, `CassiniRecordingTests`, `CassiniWhistleTests`) plus the vendored CC0 conformance vectors and shared Library vectors.
- `Cassini/` — the macOS app (SwiftUI; Library window, document-based `.opus` viewer with TextKit 2 transcript and `AVAudioEngine` playback, and native recording window).
- `QuickLook/` — the Quick Look preview extension (title, speakers, first turns).
- `docs/implementer-notes.md` — the design reference the `.opus` viewer is built against, alongside milestone notes in [`docs/`](docs/).

## Implementation notes

- Playback of portable `.opus` files uses `AVAudioEngine` + `AVAudioFile`, not `AVPlayer`: CoreMedia's Ogg demuxer seeks by byte estimate and lands up to two seconds away from the time it reports, and its duration is an estimate. `AVAudioFile` decodes Ogg Opus frame-exactly (its `length` equals the spec's playable sample count), so the word highlight follows what is actually heard.
- Saved `Recording-*` folders in the Library preview play through `AVMutableComposition` (`Sources/CassiniPlayback/SessionComposition.swift`), placing each validated WAV on its `startOffsetMs` timeline without rewriting source files.
- The `.opus` reader is a `full`-profile consumer: it verifies the audio digest on open and ends in one of the spec's six trust states, shown in the inspector's badge.
- Native capture uses Core Audio process taps (`AudioProcessTap`) and `AVAudioEngine`. Browser helpers can be shared across tabs, so a selected process may include several tabs. System capture includes other apps and notifications. An independently captured microphone also records while the meeting app is muted.
- Recording sessions contain PCM WAV files plus `session.json` with source labels and timing offsets. Browser track IDs/labels are not verified speaker identities. Partial recordings are preserved on disconnect; source/device format changes stop with an explanation. Recording currently does not generate transcripts or export the final Cassini portable Opus format. Safari/Firefox and meeting-specific participant metadata are not implemented.
- Native continuity uses the first host timestamp plus sample counts; later device-clock drift is diagnostic. Each source has ten seconds of bounded writer buffering. Overflow becomes counted silence and an interrupted result. Multichannel microphone input records channels 1 and 2, with a visible notice. Swift tests cover one-hour ±50 ppm drift, queue stalls, quantization, multichannel input, fail-once behavior and late callbacks.
- Opening a recording tolerates fractional GNOME timestamps and reads authoritative WAV frame counts. Damaged/missing metadata can be recovered read-only; unknown labels and relative start times are explicitly reported. Metadata is synced before atomic replacement. Browser recordings remain user-selectable through **Open Recording Folder…** in the Recording window; the Library also scans `~/Music/Cassini` directly.

### Developer browser-host registration

From a git checkout, after loading `BrowserExtension` as an unpacked extension in `chrome://extensions`:

```sh
scripts/install-browser-host.sh YOUR_EXTENSION_ID
```

This developer command builds and ad-hoc signs the local host and registers it only in existing Chrome, Chromium, Edge and Brave user directories. Alternatively, pass `/path/to/Cassini.app` as a second argument to register its bundled signed host without a Swift build. Rerun after moving the app or changing the extension ID. `scripts/install-browser-host.sh --uninstall` removes registrations, retaining the app/helper and recordings.

The browser/native interface is documented in [the portable v1 protocol](docs/browser-recording-protocol.md) for reuse by the GNOME recorder. The production PCM sink and browser capture paths have automated generated-tone coverage. The Core Audio hardware test is available but currently blocked on macOS system-audio consent on the development Mac; real meeting/device compatibility still needs live validation.

## Recording tests

```sh
swift test
node --test BrowserExtension/tests/*.test.cjs
python3 browser-protocol/conformance/run.py .build/debug/cassini-browser-host
python3 browser-protocol/verify.py --pinned BrowserExtension
```

Real Chromium tests (generated audio only; failure artifacts are retained):

```sh
swift build
npm ci --prefix BrowserExtension/tests
BrowserExtension/tests/node_modules/.bin/playwright install chromium
node BrowserExtension/tests/synthetic-capture.mjs
node BrowserExtension/tests/extension-capture.mjs
node BrowserExtension/tests/tab-capture.mjs
```

Playwright is pinned to 1.61.1 / Chromium 149. Tests print the actual browser version. The first exercises distinct 440/880 Hz local/remote peers, 660 Hz replacement, mute, sender removal/restore, shared timing, and a three-second SIGSTOP of the native host. The second loads the extension after 35 seconds idle and explicit worker termination, then tests normal stop, iframe capture and navigation interruption through native messaging. The third checks tabCapture, offscreen recording, stereo spectral identity, and cleanup. The tests use temporary browser profiles; the tab test supplies Chromium's invocation grant with its test-only extension allowlist, while the recording APIs run normally. A brief generated tone may be audible. `CASSINI_NATIVE_HOST` can select another executable host for Linux compatibility tests. `PLAYWRIGHT_MODULE` may select a different installed Playwright for compatibility diagnostics. Failures retain generated session files under `BrowserExtension/tests/artifacts`; CI uploads those files and test logs. The headless tests do not prove a real toolbar/keyboard invocation. GNOME has separate Xvfb user-gesture and live Nextcloud Talk tests; those are not Mac evidence.

Native audio checks (Debug build only):

```sh
scripts/check-native-recording.sh --sink-only # no microphone or system-audio permission
scripts/check-native-recording.sh             # actual Core Audio tap; macOS consent needed
```

Both check stereo separation with generated 440/880 Hz tones. The sink-only check covers planar and interleaved input, frame counts and the production WAV writer. The full check captures only Cassini's own generated tone and never opens the microphone. It launches through LaunchServices so macOS attributes consent to Cassini instead of an SSH process. The script exits nonzero on failure and removes its generated recordings. The full hardware check is a manual release gate: it remains unverified until macOS system-audio consent can be granted on this Mac. It does not bypass TCC. There is no input device here, so microphone hardware validation also remains outstanding.

## Conformance

```sh
swift build
cd Tests/CassiniKitTests/Conformance
python3 run-conformance.py --adapter ../../../.build/debug/cassini-inspect --profile full
```

Currently 26 pass, 0 warn, 0 fail on the full profile.

### Native recording in CI

All CI runs on GitHub-hosted runners. The `native` job in `.github/workflows/ci.yml` runs the generated-PCM sink check against the Debug app built once per push, on pull requests, `main`, nightly and `workflow_dispatch` like every other CI job. It covers planar and interleaved input, frame counts, stereo 440/880 Hz separation and the production WAV writer, without microphone or system-audio permission. The native session and writer Swift tests run in the `kit` job's full `swift test`.

The actual Core Audio process tap and real tabCapture need genuine macOS system-audio consent and a working output device, which hosted runners do not have. They are manual checks on a developer Mac: `python3 scripts/run-native-ci.py --mode full` (or `scripts/check-native-recording.sh`) and `node BrowserExtension/tests/tab-capture.mjs`. Consent/output-device timeouts produce `status: "blocked"` in `result.json` and still exit nonzero. Logs and `result.json` are uploaded even on failure. Diagnostic processes have a 45-second watchdog; the harness has an independent timeout and only terminates its own diagnostic. No private account credentials or recordings are put into workflow artifacts.

### Shared protocol ownership and product checks

The canonical repository is https://github.com/codemyriad/cassini-browser-protocol. Protocol, extension, schema and fixture changes are committed/pushed there first. This app records its exact upstream revision in `browser-protocol/PINNED_COMMIT`; the offline verifier checks the Git commit/tree as well as file checksums and the installed extension. To update, run the upstream `vendor.py COMMIT /path/to/cassini-mac/browser-protocol /path/to/cassini-mac/BrowserExtension`. The helper preserves this app's separate browser adapters and installed test dependencies.

SPEC v1.1 keeps wire version 1. Both native recorders use the same session folder contract; Mac writes `source: "macos"`, GNOME writes `"gnome"`, with one WAV per microphone/system/application source. Swift loader tests read both shared native-fixture variants.

Manual compatibility priorities are Teams web, Zoom web, then Meet; checklists and the per-version result template are under `browser-protocol/products/`. Controlled topology fixtures cover mixed receivers, a PC-free Web Audio path requiring tab fallback, and three receive slots whose speaker content changes without changing receiver identity. They do not claim that a live vendor version is compatible. Chromium-only and Chrome 116 minimum remain in scope; live product/account tests, Firefox and Flatpak are separate follow-up work.

Hosted macOS runs WebRTC, media/iframe, worker-lifecycle and protocol checks. Real tabCapture is a manual check on a developer Mac: hosted macOS's Null Audio Device is not a reliable rendering target. The tab test waits for saved audio frames, not a fixed startup delay. Consent/output-device timeouts produce `status: "blocked"` in native `result.json` and still exit nonzero, so an unavailable hardware gate cannot be mistaken for a passing code test.

## Releases and packaging

### Cutting a release

Maintainers publish an update by pushing a new `v*` version tag on a tested commit. The release workflow runs the package tests, builds the app, and publishes a zip and SHA-256 checksum. Use a new tag for each version. Developer ID signing and notarization remain pending until the company's Apple Developer membership and signing credentials are ready.

### Release setup for manual product runs (M3)

The release zip contains `Cassini/Cassini.app`, `BrowserExtension`, `Install Browser Host.command`, `README.txt` and the pinned protocol revision. Extract the whole folder and follow its README: approve/open the app if Gatekeeper requires it, load the extension in Chrome's Developer mode, then double-click the installer and paste its extension ID. Setup uses only the bundled executable and macOS's shell. Xcode, Swift, Python and Homebrew are not required by release users.

Keep the extension directory in a permanent location. The installer uses the app beside it, or `/Applications/Cassini.app` if the app has been moved there. Rerun after moving the app or changing the extension ID. `Install Browser Host.command --uninstall` removes registrations and retains recordings. Existing Chrome/Chromium/Edge/Brave user directories are registered; other browsers are not created. The host's setup mode is separate from framed native stdio.

Build/package for review:

```sh
xcodegen generate
xcodebuild -project Cassini.xcodeproj -scheme Cassini -configuration Release -derivedDataPath build build
python3 scripts/package-release.py build/Build/Products/Release/Cassini.app build/Cassini-recording.zip
sudo python3 scripts/check-release-install.py build/Cassini-recording.zip --report /tmp/cassini-release-install.json
```

The last check creates and removes its own hidden, non-login local account. It verifies the standard Chrome NativeMessagingHosts path, executable/allowlist/permissions, real Release-host stdio recording in that account, and uninstall preserving the recording. The test's child processes have an invalid `DEVELOPER_DIR` to detect accidental compiler use. The M3 check passed on DrMeyers. Interactive Chrome Load unpacked and downloaded-file Gatekeeper approval remain manual checks; command installation and native stdio are the automated clean-account coverage. CI/release workflows use the same packager and include the SHA256 sidecar.

The M4 [native manual check](docs/native-audio-manual-check.md) records the consent-dependent full-run gate and the tap-only idle/zero-buffer behavior. The diagnostic timeout is bounded; the production five-second waiting notice only applies after Core Audio start has returned. The SDK's tap auto-start option can wait for the selected process's first audio, so that case must be observed explicitly once hardware permission is available.
