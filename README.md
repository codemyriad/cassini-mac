# Cassini for Mac

A native macOS viewer for [Cassini portable meeting](https://format.gocassini.com/) files:
ordinary Ogg Opus `.opus` recordings that carry their own transcript, speakers and
provenance in their tags.

Open a file, play it, and read along: the spoken word is highlighted as it is said,
clicking a word seeks to it, and the transcript scrolls to follow playback.

## Layout

- `Sources/CassiniKit` — the format reader (Ogg pages, OpusTags, chunk sets, manifest,
  `cassini.words.v1`, the `exact-opus-audio-v1` audio digest), the turn/timeline model
  and transcript export. No dependencies beyond Foundation, CryptoKit and zlib.
- `Sources/cassini-inspect` — a CLI that prints a conformance-suite observation for a file
  (`--summary` for a readable report, `--metadata` to skip the audio check).
- `Tests/CassiniKitTests` — Swift tests plus the vendored CC0 conformance vectors.
- `Cassini/` — the macOS app (SwiftUI, document-based).

## Conformance

```
swift build
cd Tests/CassiniKitTests/Conformance
python3 run-conformance.py --adapter ../../../.build/debug/cassini-inspect --profile full
```

Currently 26 pass, 0 warn, 0 fail on the full profile.
