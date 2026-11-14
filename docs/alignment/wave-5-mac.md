# Wave 5 Mac alignment (D-973)

The shared contracts are in `codemyriad/cassini-ux`. This pass restores the
four Settings tabs from HARMONY §10: Recording, Transcription, Library and
Browser companion. D34.2's Sparkle controls remain available as an Updates
group after the Recording controls. The Transcription network explanation
includes update checks only when a real updater is available (D15).

Settings keeps the local companion setup guide reachable after a healthy
connection, so another supported browser can be added. Connection status,
repair guidance, per-tab reload advice, and no-browser gating continue to use
the existing production state and shared strings (D37.4, D39).

## First-run dependency

D-1010's 14 November comment advances the desktop hero under D-956; phones
remain gated by D-937. COMPONENTS §8 specifies the Saturn mark, two left-aligned
headline lines, Record with a decorative waveform, the how-to line and the
existing privacy wording until L-09 closes.

The shared catalog at `2d4415dc89ff50850e018fef7dd22c8c89582f63` (this app's pin)
and the current shared repository contain neither hero headline. The referenced
`LibraryEmpty` JSON/PNG still draws the old microphone layout. D-956's comment
also says not to infer the unbriefed layout from the Phase 1 briefs. This PR
therefore preserves current first-run behaviour and approved privacy copy.
Finishing the hero requires published localized strings and a current desktop
build brief; do not add English literals or modify the vendored catalog locally.
The local fixture renderer now supports first run and all four Settings pages
for the eventual light/dark comparison.

## Verification

- `python3 scripts/check-ux-copy.py`: catalog pins, allowed platforms and keys.
- `python3 scripts/check-brand-tokens.py`: shared token parity and colour usage.
- `python3 scripts/test-render-local-ux.py`: all page selections, dimensions,
  completion/error handling and ownership of fixture processes.
- `LibraryBoards.testSettingsRecordingPreferenceAndTabs`: four tabs, first-record
  preference, shortcut sheet, Updates controls, Library actions and Browser tab.
- `LibraryBoards.testCompanionHealthUsesExplicitTabAdviceAndFileCheckedSetup`:
  healthy connection can open the local guide, explicit repair/reload states.
- `LibraryBoards.testSettingsTranscriptionModelChoices`: existing model controls
  and no update-network claim in fixture builds without an updater.
