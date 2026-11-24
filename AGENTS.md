# AGENTS.md — Working on `cassini-mac`

For cross-app contracts, Linear workflow, PR conventions (`Seat:` line, labels, cross-model review), and the bug-classes checklist (`review/BUG-CLASSES.md`), read [`codemyriad/cassini-ux/AGENTS.md`](https://github.com/codemyriad/cassini-ux/blob/main/AGENTS.md) first.

## Key entrypoints in this repository

- [`CONTRIBUTING.md`](CONTRIBUTING.md) — Build commands, module layout, test tiers, protocol pinning, and release packaging.
- [`docs/README.md`](docs/README.md) — Architecture, recording, transcription, export, CI, and release documentation.
- [`release-notes.d/README.md`](release-notes.d/README.md) — When and how to add a user-facing release note fragment (never delete published fragments).

## Standing rules

- **Shared UX pins:** Never edit vendored copies of `cassini-ux` strings, tokens, import types, or vectors locally. Update `cassini-ux` first, then run `scripts/sync-ux.py` and commit the updated pin.
- **Browser protocol pins:** Never edit `browser-protocol/` or `BrowserExtension/` locally without landing the change in `codemyriad/cassini-browser-protocol` first and re-vendoring.
- **Determinism:** No wall-clock assertions or fixed sleeps in tests (D88). Keep contract and unit checks deterministic and offline.

## Fast local checks

```sh
python3 scripts/check-ux-copy.py
python3 scripts/check-brand-tokens.py
python3 scripts/check-badge-labels-pin.py
python3 browser-protocol/verify.py --pinned BrowserExtension
python3 scripts/test-ci-contract.py
swift test
```
