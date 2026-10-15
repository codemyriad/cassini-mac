# Cassini for Mac

A native macOS viewer for [Cassini portable meeting](https://format.gocassini.com/) files:
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
