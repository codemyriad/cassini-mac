# Meeting view (W3-1)

HARMONY §§3, 5–8 and 10, boards 17/18, and LIBRARY-RULES R12 define this page.
Library Read and received-file Play push it in the one Library window. Open and
Finder route external Opus files to the same page without importing or editing
files (UX4 follows). Back stops playback. Source/offline updates and window closure
cancel loads and release player/file access.

Speaking shares use real item durations and largest remainder (first-speaking
order breaks ties). Highlighting and click-to-seek use each item's real bounds:
sentence items stay sentences; D11 word items highlight individual words. The
fixture therefore shows 43/36/21, and the whole active sentence, as R12 requires.

Session playback adds bounded seeks with serialised completion, paused preparation,
position observation and rate changes. Opus retains frame-based AVAudioEngine
playback. The bar and keyboard use 10-second skips and HH:MM:SS elapsed/total.

Close and Quit use confirmation 1. Return stops-and-keeps; Esc keeps recording.
Window close then closes either way; quitting with Keep recording cancels Quit.
A delegate proxy preserves SwiftUI's window delegate and tears down after close.
Known transcript issues use the reusable inline line. Undrawn file/playback errors
retain system error presentation under HARMONY §5.

The companion suggestion's Not now persists. Its Set up opens existing release
setup instructions. Native broker/connected status and the two-step setup remain
UX10; no new shared protocol is introduced here. Export and More actions remain
insensitive until their assigned scope/copy. Speaker naming, Summary, inspector,
Share, Follow Along and in-meeting find are absent from this reading path.

Hosted-only UI tests render meeting.png at 1120×720 with the main fixture frozen
at 192000 ms without starting playback/capture. They exercise navigation, external
opens, rates/skips, persistent suggestion dismissal and confirmation keyboard roles.
Local verification builds the app/UI tests without launching and runs device-free
transport, share, schema/format/state and Library fixture tests.
