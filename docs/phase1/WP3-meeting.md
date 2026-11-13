# WP3 implementation handoff (big-mac)

Prerequisite: merged WP1 from agy-mac, canonical UX 5e0c34e0f1bb390298dabdf4eedc494e933fd329. Rebase this preparation onto that main before integration; no copying an open WP1 branch. #263 merged as 71c7ec8. WP2 sidebar/search belongs to agy-mac.

The Phase 1 decisions log wins. L-22/L-43/L-44 specify one-step detail open, inline renameable speakers, in-meeting Find, floating player and compact scrolled header. No summary exists: no Summary/Transcript tabs. Preserve existing transcript anatomy, gap/error actions, listening transport/shortcuts, export and trash semantics. No new Recently Deleted store; the existing move-to-system-Trash action stays the backend. No speaker saved-voice backend or Phase 2 work.

## Integration boundary

- LibraryView keeps the Library sidebar and its WP2-owned search/rows. Replace the old detail preview with an extracted Meeting pane; route selection and search-result navigation into the same pane. Keep the sidebar on opening a meeting rather than switching the whole root to MeetingView.
- MeetingView owns the page heading (rename pencil, date/duration), inline speaker names (dot, recognised marker, soft underline when unnamed), Find and transcript/player. Move existing speaker controls into header-accessible controls rather than losing listening, provenance or talk-share information.
- Header actions stay in one Export/trash capsule; recording details remains reachable from More. The toolbar has no Library title. The compact meeting title/date appear only after the page heading scrolls away.
- Native TextKit selection, Copy/Select All and seeking survive find highlights. A query searches the displayed host paragraph including inline asides, uses UTF-16 ranges and exposes deterministic next/previous matches. Query work runs off MainActor, cancels on query/meeting change, and cannot apply stale results. Find navigation scrolls to the match without starting playback. Search-result open lands at the matched line without autoplay unless Play was chosen.
- Player is a floating raised surface with token line/shadow. Keep real transport, seek/readout, rate and listening controls. Leave enough transcript bottom inset to read the final turn; verify hit-testing and VoiceOver.

## Boards inspected

`boards/ui/LibraryOpen-Mac*.dc.html` is the current pane reference (1120×720, 400 sidebar, 52 toolbar; content inset 44; heading 22 bold; inline 7px speaker dots; player inset 28, bottom 16). Meeting-Mac* is older separate speakers-page anatomy and loses to L-43/L-44. Player-Mac is a component reference; the current pane board's compact 40px floating player is the integration reference. Find/scrolled light/dark wrappers import the same LibraryOpen component. No summary is implemented even though the board's default tab includes a summary mock.

Recording-Mac*: next WP4, compact 30px timer/Stop, one source card, native existing meters, mic silence warning, recording details in More. Transcribing-Mac*: WP5, empty desktop transcript until complete, status line/thin bar/Stop and chevron popover; no live draft invention. Speakers-Mac*: WP6, floating single-column dialog, quote/name, footer merge/cancel/save; flag absent saved voices instead of inventing it.

## Verification / screenshots

Before/after actual app boards in light and dark for open meeting, Find and scrolled state; use ui-shots CI plus tools/pr-shots diff artifact. App seats do not run pr-shots publish/prune (coordinator publishes). Preserve baseline/head SHAs and run provenance. Add event-driven UI checks for single selection open, Cmd-F query/next/previous/highlight, scroll compact header, search hit landing, accessible transport and inline speaker rename. Run relevant pure Find tests and native app checks under ~/bin/heavy-run (two shared slots). Ready only after exact-head CI and pr-shots green; Seat: big-mac; no AI attribution lines in commits.

## Preparation verification

On base main `71c7ec82` (merged #263), the six `TranscriptFindTests` pass in the actual CassiniLibrary test target. A Debug arm64 app build with Xcode 16.4 / macOS SDK 15.5 compiles MeetingFindModel and MeetingFindBar successfully. No app was launched, no devices were opened, and both runs used heavy-run. Evidence: `~/coordination/evidence/phase1-wp3/{find-tests-final,native-preparation}`. Project generation was used only for the local build and reset afterward; regenerate from merged WP1 during integration.

These Find components are preparation only: not wired to the meeting page, no UI outcome or screenshot proof is claimed yet. Push this checkpoint to remote `prep/phase1-wp3-find`. The local integration branch `feat/phase1-wp3-meeting` remains unpublished under its final name, so it can rebase onto merged WP1 without force-pushing any public branch. Then wire the page and open the single WP3 PR on main.
