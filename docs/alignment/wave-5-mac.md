# Wave 5 Mac alignment (D-973)

First run uses COMPONENTS §8 / L-27: the pinned Saturn mark, two left-aligned
headline lines at 64 pt in the platform font, and Record at the start of a
static waveform. The waveform uses square 4 pt bars, the brand accent role,
and a fade at both ends. Its provisional count, height pattern and geometry
are named constants in `FirstRunWave` and `FirstRunHeroMetrics`. The Library
heading is available to accessibility without a visible toolbar title.

The hero scales each sentence to remain on one line in narrow windows. A
compact layout keeps Record reachable at the 760 × 480 minimum; the content
can scroll vertically. The decorative wave has no animation, audio input,
permission request or accessibility stops. Record uses the existing consent
and capture path. The native About panel reuses the cached Saturn mark.

The how-to, shortcut and current privacy line follow the waveform. Privacy
wording remains the published desktop wording until L-09 closes; a custom
Library location retains its existing folder-path disclosure. No phone backup
qualifier is shown on Mac. Shared catalog bytes are pinned to
`31973ff9784fcc66c1c7993b903a336e8f2c1432`, which publishes both hero lines in
all six languages; neither vendored copy is edited independently.

Settings has HARMONY §10's four tabs: Recording, Transcription, Library and
Browser companion. D34.2's Sparkle controls are an Updates group after the
Recording controls. The Transcription network explanation mentions update
checks only when a real updater is available (D15).

Settings keeps Add from Cassini reachable after a healthy companion connection,
so another supported browser can be added. Connection status, repair guidance,
per-tab reload advice and no-browser gating retain the existing production
state and shared strings. Tests query the link by identifier because macOS
exposes a link-style SwiftUI Button as an AXLink.

## Verification

- `scripts/check-ux-copy.py`: both catalog copies, pins, platforms and used keys.
- `scripts/check-brand-tokens.py`: shared token parity and colour usage.
- `scripts/test-render-local-ux.py`: all four Settings pages, first run, language,
  theme, dimensions, errors and ownership of fixture processes.
- `scripts/test-export-ux-boards.py`: paired light/dark screenshot inventory.
- `LocalizationTests`: all catalog translations and placeholder handling.
- `LibraryBoards.testFirstRun`, `testFrenchLibraryAndFirstRunFitAtBoardSize`
  and `testFirstRunHeroFitsMinimumWindow`: localized hero, one-line sentences,
  hidden Library heading, reachable Record and first-record consent.
- `LibraryBoards.testSettingsRecordingPreferenceAndTabs`: four tabs, existing
  preferences, shortcut sheet, Updates controls, Library actions and Browser tab.
- `LibraryBoards.testCompanionHealthUsesExplicitTabAdviceAndFileCheckedSetup`:
  healthy connection opens/closes the local guide; explicit repair/reload states.
- `LibraryBoards.testSettingsTranscriptionModelChoices`: model controls and no
  update-network claim in builds without an updater.
- `SettingsSelfTest`: About assets and existing licences remain available.

## Visual evidence

`d973-pr-shots/` contains light/dark before, after and difference images generated
with the shared `tools/pr-shots/pr-shots.py`. These are frozen renders of Cassini's
own views on the local Mac, not desktop captures or proof of user interaction.
The before build uses main's relevant views with the same fixture harness. The
disconnected Browser comparison covers the tab strip; the connected guide
interaction is covered separately by the hosted UI regression.
