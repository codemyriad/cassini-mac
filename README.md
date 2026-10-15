# Cassini for Mac

A native macOS viewer for [Cassini portable meeting](https://format.gocassini.com/) files:
ordinary Ogg Opus `.opus` recordings that carry their own transcript, speakers and
provenance in their tags.

Open a file, play it, and read along: the spoken word is highlighted as it is said,
clicking a word seeks to it, and the transcript scrolls to follow playback.

## Download

Builds are published on the [Releases page](https://github.com/codemyriad/cassini-mac/releases):
sign in to GitHub with an account that has access to this private repository, download
`Cassini-<version>.zip`, unzip, and move `Cassini.app` to Applications. Requires macOS 15
or later; the v0.1.0 release supports both Intel and Apple Silicon Macs.

These early builds are ad-hoc signed and not notarized. After attempting to open Cassini,
if macOS blocks it because the developer cannot be verified, open **System Settings →
Privacy & Security**, find the Cassini warning, and choose **Open Anyway**. Confirm the
prompt. Only do this for the release you intentionally downloaded from this repository.
See [Apple's instructions](https://support.apple.com/102445). Managed Macs may require
an administrator to allow the app.

### Updates for colleagues

Bookmark the [latest release](https://github.com/codemyriad/cassini-mac/releases/latest).
To update, quit Cassini, download and unzip the newer release, then replace `Cassini.app`
in Applications and reopen it. There is no in-app updater yet. GitHub's **Watch → Custom →
Releases** option can notify you when a new build is published. Keep your meeting files;
updating the app does not require deleting them.

Maintainers publish an update by pushing a new `v*` version tag on a tested commit. The
release workflow runs the package tests, builds the app, and publishes a zip and SHA-256
checksum. Use a new tag for each version. Developer ID signing and notarization remain
pending until the company's Apple Developer membership and signing credentials are ready.

## Layout

- `Sources/CassiniKit` — the format reader (Ogg pages, OpusTags, chunk sets, manifest,
  `cassini.words.v1`, the `exact-opus-audio-v1` audio digest), the turn/timeline model
  and transcript export. No dependencies beyond Foundation, CryptoKit and zlib.
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
