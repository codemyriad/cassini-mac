# Cassini for Mac

A native macOS viewer for [Cassini portable meeting](https://format.gocassini.com/) files:
ordinary Ogg Opus `.opus` recordings that carry their own transcript, speakers and
provenance in their tags.

Open a file, play it, and read along: the spoken word is highlighted as it is said,
clicking a word seeks to it, and the transcript scrolls to follow playback.

## Download

Builds are published on the [Releases page](https://github.com/codemyriad/cassini-mac/releases):
download `Cassini-<version>.zip`, unzip, and move `Cassini.app` to Applications. The builds are
not notarized yet, so on first launch right-click the app and choose Open (or
`xattr -d com.apple.quarantine /Applications/Cassini.app`). Requires macOS 15.

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
