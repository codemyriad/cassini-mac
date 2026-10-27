# Cassini for Mac

A native macOS viewer and local meeting recorder for [Cassini portable meeting](https://format.gocassini.com/) files:
ordinary Ogg Opus `.opus` recordings that carry their own transcript, speakers and
provenance in their tags.

Open a file, play it, and read along: the spoken word is highlighted as it is said,
clicking a word seeks to it, and the transcript scrolls to follow playback.

## Download

Builds are published on the [Releases page](https://github.com/codemyriad/cassini-mac/releases):
download `Cassini-<version>.zip`, unzip, and move `Cassini.app` to Applications. While the
repository is private, downloading needs a GitHub account with access to it. Requires macOS 15
or later; the builds are universal (Intel and Apple Silicon).

These early builds are ad-hoc signed and not notarized, so macOS 15 blocks the first launch.
The right-click → Open shortcut of older macOS versions no longer works; do this instead:

1. Double-click `Cassini.app`. macOS shows a dialog titled **“Cassini” Not Opened** saying Apple
   could not verify it is free of malware. Click **Done**, not Move to Trash.
2. Right away, open **System Settings → Privacy & Security**, scroll to the Security section,
   and click **Open Anyway** next to the Cassini notice. The notice only appears after a blocked
   launch and disappears after a while; if it is missing, open Cassini again and look again.
3. Confirm the prompt and enter an administrator password or Touch ID. This needs an admin
   account on the Mac. On company-managed Macs the button may be hidden by policy; ask IT to
   allow the app.

Do this only for a build you downloaded from this repository. See
[Apple's instructions](https://support.apple.com/102445).

### Updates for colleagues

Bookmark the [latest release](https://github.com/codemyriad/cassini-mac/releases/latest).
To update, quit Cassini, download and unzip the newer release, then replace `Cassini.app`
in Applications and reopen it. Each build is a separately signed app, so expect the steps
above again. There is no in-app updater yet. GitHub's **Watch → Custom → Releases** option
can notify you when a new build is published. Updating the app leaves your meeting files alone.

### Cutting a release

Maintainers publish an update by pushing a new `v*` version tag on a tested commit. The
release workflow runs the package tests, builds the app, and publishes a zip and SHA-256
checksum. Use a new tag for each version. Developer ID signing and notarization remain
pending until the company's Apple Developer membership and signing credentials are ready.

## Recording (development preview)

Choose **File → New Recording…** (⌘N). Select system output, specific audio processes, or
microphone only; optionally include the microphone as a separate track. Start Recording
asks for a destination folder and the required macOS audio permissions. Meters show incoming
audio. Stop Recording finalizes the files; quitting also stops and saves. Closing the
recording window leaves capture running, and ⌘N brings it back.

Native capture uses Core Audio process taps and AVAudioEngine. Browser helpers can be shared
across tabs, so a selected process may include several tabs. System capture includes other
apps and notifications. An independently captured microphone also records while the meeting
app is muted.

For browser tracks or a single tab, load the Chromium extension:

1. Open the browser’s extensions page, enable **Developer mode**, and **Load unpacked** the
   `BrowserExtension` directory. It installs early hooks on HTTP/HTTPS pages but captures only
   after you press Record. Reload meeting pages after installation.
2. Copy the extension ID and run from this checkout:
   ```sh
   scripts/install-browser-host.sh YOUR_EXTENSION_ID
   ```
   This developer command builds and ad-hoc signs the local host and registers it only in existing Chrome,
   Chromium, Edge and Brave directories. Alternatively, pass `/path/to/Cassini.app` as a
   second argument to register its bundled signed host without a Swift build. Rerun after
   moving the app or changing the extension ID. `scripts/install-browser-host.sh --uninstall`
   removes registrations, retaining the app/helper and recordings.
3. In the meeting tab, open the extension and choose **Record separate tracks**. If the page
   blocks access or no tracks are found, choose **Record the whole tab**. The tab fallback preserves
   playback and records the rendered mix; it usually excludes your microphone. Use native
   output + microphone capture when you need that fallback.
4. **Stop and save** writes to `~/Music/Cassini/Recording-<UUID>`. In Cassini’s recording window,
   use **Open Recording Folder…** to listen to separate tracks or all tracks together.

Audio stays local. Sessions contain PCM WAV files plus `session.json` with source labels and
timing offsets. Browser track IDs/labels are not verified speaker identities. Partial recordings
are preserved on disconnect; source/device format changes stop with an explanation. Recording
currently does not generate transcripts or export the final Cassini portable Opus format.
Safari/Firefox and meeting-specific participant metadata are not implemented.

The browser/native interface is documented in [the portable v1 protocol](docs/browser-recording-protocol.md)
for reuse by the GNOME recorder. The production PCM sink and browser capture paths have automated generated-tone coverage.
The Core Audio hardware test is available but currently blocked on macOS system-audio consent
on the development Mac; real meeting/device compatibility still needs live validation.

### Recording tests

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

Playwright is pinned to 1.61.1 / Chromium 149. Tests print the actual browser version.
The first exercises distinct 440/880 Hz local/remote peers, 660 Hz replacement, mute,
sender removal/restore, shared timing, and a three-second SIGSTOP of the native host.
The second loads the extension after 35 seconds idle and explicit worker termination,
then tests normal stop, iframe capture and navigation interruption through native messaging. The third checks tabCapture,
offscreen recording, stereo spectral identity, and cleanup. The tests use temporary browser
profiles; the tab test supplies Chromium's invocation grant with its test-only extension
allowlist, while the recording APIs run normally. A brief generated tone may be audible.
`CASSINI_NATIVE_HOST` can select another executable host for Linux compatibility tests.
`PLAYWRIGHT_MODULE` may select a different installed Playwright for compatibility diagnostics.
Failures retain generated session files under `BrowserExtension/tests/artifacts`; CI uploads
those files and test logs. The headless tests do not prove a real toolbar/keyboard invocation.
GNOME has separate Xvfb user-gesture and live Nextcloud Talk tests; those are not Mac evidence.

Native audio checks (Debug build only):

```sh
scripts/check-native-recording.sh --sink-only # no microphone or system-audio permission
scripts/check-native-recording.sh             # actual Core Audio tap; macOS consent needed
```

Both check stereo separation with generated 440/880 Hz tones. The sink-only check covers
planar and interleaved input, frame counts and the production WAV writer. The full check
captures only Cassini's own generated tone and never opens the microphone. It launches
through LaunchServices so macOS attributes consent to Cassini instead of an SSH process.
The script exits nonzero on failure and removes its generated recordings. The full hardware
check is a manual release gate: it remains unverified until macOS system-audio consent can
be granted on this Mac. It does not bypass TCC. There is no input device here, so microphone
hardware validation also remains outstanding.

Native continuity uses the first host timestamp plus sample counts; later device-clock drift
is diagnostic. Each source has ten seconds of bounded writer buffering. Overflow becomes
counted silence and an interrupted result. Multichannel microphone input records channels
1 and 2, with a visible notice. Swift tests cover one-hour ±50 ppm drift, queue stalls,
quantization, multichannel input, fail-once behavior and late callbacks.

Opening a recording tolerates fractional GNOME timestamps and reads authoritative WAV frame
counts. Damaged/missing metadata can be recovered read-only; unknown labels and relative start
times are explicitly reported. Metadata is synced before atomic replacement. Browser recordings
remain user-selected through Open Recording Folder; the app does not need broad Music access.

## Layout

- `Sources/CassiniKit` — the format reader (Ogg pages, OpusTags, chunk sets, manifest,
  `cassini.words.v1`, the `exact-opus-audio-v1` audio digest), the turn/timeline model
  and transcript export. No dependencies beyond Foundation, CryptoKit and zlib.
- `Sources/CassiniRecording` — incremental WAV sessions and portable browser/native protocol.
- `Sources/cassini-browser-host` — local Chromium Native Messaging host.
- `BrowserExtension` — early WebRTC hooks, tab capture fallback, worklet and integration tests.
- `Sources/cassini-inspect` — a CLI that prints a conformance-suite observation for a file
  (`--summary` for a readable report, `--metadata` to skip the audio check).
- `Tests/CassiniKitTests` — Swift tests plus the vendored CC0 conformance vectors.
- `Cassini/` — the macOS app (SwiftUI, document-based; TextKit 2 transcript; AVAudioEngine playback).
- `QuickLook/` — the Quick Look preview extension (title, speakers, first turns).
- `docs/implementer-notes.md` — the design reference the app is built against.

## Building

```
brew install xcodegen
xcodegen generate
xcodebuild -project Cassini.xcodeproj -scheme Cassini -configuration Debug -derivedDataPath build build
open build/Build/Products/Debug/Cassini.app Samples/your-meeting.opus
```

Requires macOS 15 and Xcode 16. The app is sandboxed and ad-hoc signed for local runs.

## Notes

- Playback uses `AVAudioEngine` + `AVAudioFile`, not `AVPlayer`: CoreMedia's Ogg demuxer seeks
  by byte estimate and lands up to two seconds away from the time it reports, and its duration
  is an estimate. `AVAudioFile` decodes Ogg Opus frame-exactly (its `length` equals the spec's
  playable sample count), so the word highlight follows what is actually heard.
- The reader is a `full`-profile consumer: it verifies the audio digest on open and ends in one
  of the spec's six trust states, shown in the inspector's badge.

## Conformance

```
swift build
cd Tests/CassiniKitTests/Conformance
python3 run-conformance.py --adapter ../../../.build/debug/cassini-inspect --profile full
```

Currently 26 pass, 0 warn, 0 fail on the full profile.

### DrMeyers native runner

The repository-scoped `DrMeyers-audio` runner is installed on DrMeyers as a user LaunchAgent,
labelled `drmeyers-audio` (`self-hosted`, `macOS`, `ARM64`). Its files live in
`~/.local/share/cassini-actions-runner`; it needs the silvio GUI login session for app/audio
validation. Manage it from that directory with `./svc.sh status|stop|start`.

`.github/workflows/native-recording.yml` runs only on `workflow_dispatch` or nightly at
02:23 UTC, and its job additionally requires this repository's `main` ref. Pull requests,
forks and pushes do not trigger native jobs. Other CI jobs continue on hosted machines.
A repository maintainer can run it with:

```
gh workflow run native-recording.yml --ref main -f mode=sink-only
gh workflow run native-recording.yml --ref main -f mode=full
```

Both modes test the native writer/session loader and real tabCapture; `full` also attempts an actual Core Audio
process tap of Cassini's generated 440/880 Hz tone. It never opens the microphone or captures
other applications. The full mode needs genuine macOS system-audio consent and a working
output device; runner registration does not grant that permission. Nightly runs sink-only until one manual full dispatch has passed after real audio consent.
Only then should the schedule be changed back to full. Manual full runs remain nonzero if
capture cannot be validated. Ad-hoc app updates can require
renewed consent. Actual microphone validation additionally needs an input device.

Logs and `result.json` are uploaded even on failure. Diagnostic processes have a 45-second
watchdog; the harness has an independent timeout and only terminates its own diagnostic.
Use `python3 scripts/run-native-ci.py --mode sink-only` for the same local check. No private
account credentials or recordings are put into workflow artifacts.


### Shared protocol ownership and product checks

The canonical repository is https://github.com/codemyriad/cassini-browser-protocol. Protocol,
extension, schema and fixture changes are committed/pushed there first. This app records its
exact upstream revision in `browser-protocol/PINNED_COMMIT`; the offline verifier checks the
Git commit/tree as well as file checksums and the installed extension. To update, run the
upstream `vendor.py COMMIT /path/to/cassini-mac/browser-protocol /path/to/cassini-mac/BrowserExtension`.
The helper preserves this app's separate browser adapters and installed test dependencies.

SPEC v1.1 keeps wire version 1. Both native recorders use the same session folder contract;
Mac writes `source: "macos"`, GNOME writes `"gnome"`, with one WAV per microphone/system/
application source. Swift loader tests read both shared native-fixture variants.

Manual compatibility priorities are Teams web, Zoom web, then Meet; checklists and the
per-version result template are under `browser-protocol/products/`. Controlled topology
fixtures cover mixed receivers, a PC-free Web Audio path requiring tab fallback, and three
receive slots whose speaker content changes without changing receiver identity. They do not
claim that a live vendor version is compatible. Chromium-only and Chrome 116 minimum remain
in scope; live product/account tests, Firefox and Flatpak are separate follow-up work.

Hosted macOS runs WebRTC, media/iframe, worker-lifecycle and protocol checks. Real tabCapture
runs in the DrMeyers manual/nightly workflow: hosted macOS's Null Audio Device is not a reliable
rendering target. The tab test waits for saved audio frames, not a fixed startup delay.
Consent/output-device timeouts produce `status: "blocked"` in native result.json and still
exit nonzero, so an unavailable hardware gate cannot be mistaken for a passing code test.


### Release setup for manual product runs (M3)

The release zip contains `Cassini/Cassini.app`, `BrowserExtension`,
`Install Browser Host.command`, `README.txt` and the pinned protocol revision. Extract the
whole folder and follow its README: approve/open the app if Gatekeeper requires it, load the
extension in Chrome's Developer mode, then double-click the installer and paste its extension
ID. Setup uses only the bundled executable and macOS's shell. Xcode, Swift, Python and
Homebrew are not required by release users.

Keep the extension directory in a permanent location. The installer uses the app beside it,
or `/Applications/Cassini.app` if the app has been moved there. Rerun after moving the app or
changing the extension ID. `Install Browser Host.command --uninstall` removes registrations
and retains recordings. Existing Chrome/Chromium/Edge/Brave user directories are registered;
other browsers are not created. The host's setup mode is separate from framed native stdio.

Build/package for review:

```
xcodegen generate
xcodebuild -project Cassini.xcodeproj -scheme Cassini -configuration Release -derivedDataPath build build
python3 scripts/package-release.py build/Build/Products/Release/Cassini.app build/Cassini-recording.zip
sudo python3 scripts/check-release-install.py build/Cassini-recording.zip --report /tmp/cassini-release-install.json
```

The last check creates and removes its own hidden, non-login local account. It verifies the
standard Chrome NativeMessagingHosts path, executable/allowlist/permissions, real Release-host
stdio recording in that account, and uninstall preserving the recording. The test's child
processes have an invalid DEVELOPER_DIR to detect accidental compiler use. The M3 check passed
on DrMeyers. Interactive Chrome Load unpacked and downloaded-file Gatekeeper approval remain
manual checks; command installation and native stdio are the automated clean-account coverage.
CI/release workflows use the same packager and include the SHA256 sidecar.

The M4 [native manual check](docs/native-audio-manual-check.md) records the consent-dependent
full-run gate and the tap-only idle/zero-buffer behavior. The diagnostic timeout is bounded;
the production five-second waiting notice only applies after Core Audio start has returned.
The SDK's tap auto-start option can wait for the selected process's first audio, so that case
must be observed explicitly once hardware permission is available.
