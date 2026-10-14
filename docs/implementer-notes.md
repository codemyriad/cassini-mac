# Cassini for Mac — implementer notes

Source: the design doc of 14 Oct 2026 (Claude Docs) and the companion design canvas. This is the
reference the app is built against; where the spec and these notes differ, the format spec wins.

## Scope

Build a native macOS app that opens a Cassini `.opus` file, plays it, and shows its transcript with
word-by-word highlighting, click-to-seek and follow-along scrolling.

A real build reads per-word `start`/`end` times from the file. Out of scope for v1: recording,
transcription, editing the transcript, and writing tags back to the file.

## Reading the file

A Cassini file is an ordinary 48 kHz Ogg Opus file. Everything else rides in its Opus comment tags,
so there is no sidecar. Follow the Cassini format spec v1 (https://format.gocassini.com/):

1. Read `OpusHead` and `OpusTags`. Keep the standard tags (`TITLE`, `ARTIST`, `DATE`) for fallback display.
2. Collect the numbered `CASSINI_PAYLOAD_000..N` comments in order and concatenate them.
3. Decode base64url, gunzip, and parse the UTF-8 JSON manifest (`cassini-portable-meeting`, version 1, profile `ogg-opus`).
4. Check each payload's SHA-256 and sizes against the manifest's payload reference.
5. Verify the audio: hash the Opus audio and compare with the manifest digest (policy `exact-opus-audio-v1`). This drives the inspector's "Audio matches transcript" badge.
6. Pick the transcript with the default flag and decode its `cassini.words.v1` body. Each word has `text`, a speaker id, and `start`/`end` in ms.
7. Resolve speaker ids to display labels from the manifest's speaker list.

Also available: meeting id, title, created time (UTC), duration, `CASSINI_AUDIO_*` fields and
provenance (producer tool, processing notes). Show provenance in the inspector.

Playback: confirm whether AVFoundation decodes Ogg Opus on the minimum macOS version you target.
If not, decode with libopusfile and feed `AVAudioEngine`. (Checked: AVFoundation decodes Ogg Opus
on macOS 15+, and `AVAudioFile.length` equals the spec's playable sample count. `AVPlayer` is
not usable for this: its Ogg seeks land up to ~2 s off the reported time and its duration is a
byte estimate, so the app plays through `AVAudioEngine` fed from `AVAudioFile`.)

Failure modes to handle: a plain `.opus` with no Cassini tags (play it, show "No transcript in this
file"); a digest mismatch (play it, show a warning badge instead of the check); a corrupt payload
(same as no transcript, plus a details line in the inspector).

## Window layout

One document window per file, with three columns: sidebar, content and inspector. The sidebar and
inspector can be collapsed.

| Region | Contents | Notes |
|---|---|---|
| Sidebar (220 pt) | Window buttons, Speakers list with checkboxes and color dots, Tags with "Add Tag", file name at the bottom | Full height, sidebar material. Shows a speaker icon next to whoever is talking now. |
| Toolbar | Sidebar toggle; title + subtitle (date · speaker count · duration); Transcript / Summary segmented control; search field; Share; inspector toggle | Unified toolbar. Subtitle comes from the manifest. |
| Transcript | One block per speaker turn: color dot, name, clickable timestamp, then the words | Reading column max 720 pt, body 15 pt, line height 1.75. Overlapping short interjections (e.g. "Yeah.") show as an inline chip in the other speaker's turn. |
| Summary | Overview paragraph, action items with checkboxes, topics with timestamps that jump to the transcript | The spec does not define summary storage yet. Hide the tab when there is none. |
| Player bar | Back 15 s, Play/Pause, Forward 15 s, elapsed, scrubber, remaining, speed (1×, 1.25×, 1.5×, 2×, 0.75×), Follow along switch | Pinned to the bottom of the content column. |
| Inspector (260 pt) | Integrity badge; Recording (duration, date, format, sample rate); Transcript (schema, speakers, timing); Show in Finder, Export… | Mirrors Finder's Get Info. |

## Word highlighting and sync

The player's clock is the only source of truth. Each frame, find the word being spoken and restyle
only the words whose state changed.

**Clock.** Read the time from the player (`AVPlayer.currentTime()`) on each display refresh:
`CADisplayLink` on macOS 14+. Don't advance a separate timer, or it will drift from the audio.
Apply the playback rate through the player, never to the highlight.

**Lookup.** On load, flatten all words into one array sorted by `start`. The current word is the
last one with `start <= t`, found by binary search. Cache the last index and check its neighbours
first, since time almost always moves forward.

**Word states.**

| State | When | Style |
|---|---|---|
| Current | Last word with `start <= t`, while `t < end + 300 ms` | Accent color at 22% opacity behind the word (50% in Dark Mode), 4 pt corner radius, text color unchanged |
| Upcoming | Later words in the active turn | Secondary label color |
| Spoken / other turns | Everything else | Primary label color |
| Active turn | `t` between the turn's first `start` and last `end` + 300 ms | Accent color at 6% opacity (12% dark), 10 pt radius |
| Search match | Word contains the query | Find highlight, yellow at 45% |

The 300 ms hold stops the highlight flickering off in short pauses. Don't change font weight or
size on the current word: the line must not reflow. Animate the background at about 120 ms ease-out.

**Overlapping speech.** Words from different speakers can overlap in time. Keep one current word
per speaker, so an interjection chip lights up while the main turn's word stays lit.

**Follow along.** When on, scroll only when the current word leaves the band from 48 pt below the
top to 96 pt above the bottom of the scroll view. Then animate it to about 35% of the view height.
If the user scrolls by hand, pause following and show a "Jump to current" button; clicking it or
seeking turns following back on.

**Seek.** Clicking a word seeks to its `start`. Clicking a timestamp seeks to the turn's first word.
Seek before you redraw, so the highlight lands in the same frame.

**Performance.** A 41-minute meeting has several thousand words. Use one `NSTextView` (TextKit 2)
per turn, or a lazily laid out list, and change attributes on the affected ranges only. Don't
create a view per word.

## Interactions and shortcuts

| Action | Mouse | Keyboard (proposed) |
|---|---|---|
| Play / pause | Play button | Space |
| Skip back / forward 15 s | 15 s buttons | ← / → |
| Seek to a word | Click the word | Return on a focused word |
| Seek to a turn | Click its timestamp | — |
| Change speed | Click the speed button to cycle | ⌘↑ / ⌘↓ |
| Search | Toolbar field; matches highlighted, count shown above the transcript | ⌘F; ⌘G / ⇧⌘G next / previous match; Esc clears |
| Filter speakers | Speaker checkboxes in the sidebar hide their turns | — |
| Follow along | Switch in the player bar | ⌘L |
| Sidebar / inspector | Toolbar buttons | ⌃⌘S / ⌥⌘I |
| Summary item | Its timestamp switches to Transcript and seeks | — |

Add the commands to the menu bar (View, Playback) so they are discoverable and can be remapped in
System Settings. Keep a Space press in the search field from toggling playback.

## macOS conventions

Build Cassini as a document-based app (`DocumentGroup`), read-only for v1, that opens `.opus` files.

- **Files:** register `.opus` as a document type with the Viewer role, so Cassini shows in Finder's Open With. Support recent documents, window restoration and drag-to-open.
- **Quick Look:** a Quick Look preview extension that shows the title, speakers and the first lines of the transcript.
- **Controls:** system controls, not custom ones: `NavigationSplitView` with an inspector, a segmented `Picker`, `.searchable` in the toolbar, `Toggle(.switch)` and `Slider` for the scrubber.
- **Colors:** system semantic colors only and the user's accent color. Speaker colors use the system orange, indigo, teal, green and pink in order.
- **Type:** SF Pro through the system font. 15 pt for transcript body, monospaced digits for times.
- **Now Playing:** register with `MPNowPlayingInfoCenter` and `MPRemoteCommandCenter`, so media keys, Control Center and AirPods controls work.
- **Accessibility:** every word is reachable with VoiceOver, its label giving the speaker and time. Announce turn changes, not every word. With Reduce Motion on, follow-along jumps instead of animating. With Increase Contrast on, use a solid accent outline for the current word.

## Open questions

- [ ] Where is the summary stored? The spec mentions it but defines no field. (The spec's `summary.md` attachment is used.)
- [ ] Tags: the spec defines no field for them. Store them in the file, or in an app-side library? (Not implemented in v1.)
- [ ] Can Cassini write to the file (tags, speaker renames), or does it stay a viewer? A write must leave the audio bytes untouched, or the digest check fails.
- [ ] Which minimum macOS version? (v1 targets macOS 15.)
- [ ] Should a library window list all meetings, or should Cassini stay a pure document app?
- [ ] What should export produce: plain text, SRT/VTT subtitles, or Markdown with timestamps? (v1 offers all four.)
