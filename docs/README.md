# Cassini for Mac — Documentation Index

Architecture, protocol, UI, CI, and release documentation for `codemyriad/cassini-mac`. Cross-app UX contracts, brand tokens, shared strings, and decision logs live in [`codemyriad/cassini-ux`](https://github.com/codemyriad/cassini-ux).

## Architecture & UI

- [`implementer-notes.md`](implementer-notes.md) — Core `.opus` viewer, playback, and architecture reference.
- [`library-shell.md`](library-shell.md) — Library shell and first-run structure.
- [`library-recording.md`](library-recording.md) — Recording directly into the Library.
- [`meeting-view.md`](meeting-view.md) — Meeting view architecture.
- [`phase1/WP3-meeting.md`](phase1/WP3-meeting.md) — Split-pane meeting view, inline speakers, and Summary/Transcript tabs.
- [`transcript-rendering.md`](transcript-rendering.md) — Shared transcript rendering contract (D84).
- [`folder-playback.md`](folder-playback.md) — Multi-track `Recording-*` folder playback.
- [`external-opening.md`](external-opening.md) — Opening external `.opus` files as imported meetings.
- [`windowless-app.md`](windowless-app.md) — Menu-bar and background recording without an open window (D41).
- [`settings-location-proposal.md`](settings-location-proposal.md) — Library relocation pointer (`~/Music/.cassini-library-location.json`, D15.1).

## Recording & Browser Companion

- [`browser-recording-protocol.md`](browser-recording-protocol.md) — Portable v1 browser/native recording protocol.
- [`browser-companion.md`](browser-companion.md) — Browser companion and owned recording sessions.
- [`local-browser-companion.md`](local-browser-companion.md) — App-supplied local browser companion setup.
- [`browser-connect.md`](browser-connect.md) — Companion connection and health states.
- [`browser-control-transport.md`](browser-control-transport.md) — Browser-control transport groundwork.
- [`browser-call-lifecycle.md`](browser-call-lifecycle.md) — Call lifecycle adoption (D33).
- [`browser-capture-owner.md`](browser-capture-owner.md) — Capture ownership rules.
- [`browser-user-stops.md`](browser-user-stops.md) — Explicit browser Stops across control reconnects (D43).
- [`browser-setup-spike.md`](browser-setup-spike.md) — Sandboxed XPC per-user browser registration spike (UX10).
- [`companion-023.md`](companion-023.md) — Browser companion 0.2.3 adoption notes.
- [`session-source-events.md`](session-source-events.md) — Session source lifecycle events.
- [`microphone-pcm-preparation.md`](microphone-pcm-preparation.md) — Microphone PCM preparation (D46).
- [`recording-spectrogram.md`](recording-spectrogram.md) — Live recording spectrogram design.
- [`native-audio-manual-check.md`](native-audio-manual-check.md) — Manual hardware/consent recording check (M4).

## Transcription & Models

- [`writing-down.md`](writing-down.md) — Bundled offline transcription (UX13).
- [`whistle-spike.md`](whistle-spike.md) — Bundled Whistle model and Needle 3.3.0 worker architecture.
- [`parakeet-runtime.md`](parakeet-runtime.md) — Optional Parakeet Ultra runtime and worker subprocess.
- [`model-downloader.md`](model-downloader.md) — Offline-verified model downloader.

## Export & Search

- [`codemyriad-export.md`](codemyriad-export.md) — Exported file namespace and format contract (R65, D55).
- [`SEARCH.md`](SEARCH.md) — Local Library full-text search index.

## CI, Screenshots & Releases

- [`ci/build-once.md`](ci/build-once.md) — Hosted CI build-once product sharing (D20).
- [`ci/known-flakes.md`](ci/known-flakes.md) — Known CI flakes and mitigations (D66).
- [`ci-optimization-d1064.md`](ci-optimization-d1064.md) — CI test tiers, runner locking, and workspace cleanup (D-1064).
- [`spectrogram-ci.md`](spectrogram-ci.md) — Spectrogram measurement policy in CI.
- [`window-screenshot-spike.md`](window-screenshot-spike.md) — Whole-window XCUITest screenshot capture.
- [`board-screenshot-spike.md`](board-screenshot-spike.md) — Board-size capture on hosted runners.
- [`developer-id-release.md`](developer-id-release.md) — Developer ID signing, notarization, and DMG build (D34).
- [`release-notes.md`](release-notes.md) — User-facing release note authoring and publication procedure.
