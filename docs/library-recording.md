# Recording into the Library (W3-2)

Record in the Library, Meeting header or menu uses RecordFirst, with the shared
platform captions and a persisted Don't show again choice. Native input checks
microphone authorization and requests it only when undetermined; the process-tap
API uses macOS's system-audio consent. Opening RecordFirst itself starts no device.

After authorization the controller creates Music/Cassini/Recording-<lowercase UUID>
and app-owned meeting.json. There is no folder chooser or separate recording
window. Session/audio are owned by RecordingSession/RecordingSink; the metadata
writer changes only meeting.json, validates the shared schema, locks transactions
across processes, writes privately and atomically, and preserves existing fields.

A four-phase controller exposes starting/recording/saving/idle. The live pill gets
its two levels from the sink and its elapsed time from the real start. Stop shuts
down inputs, finalizes WAVs/manifest off the UI thread, and reports Saving activity
until completion. The Library supplies both recording and saving activity (D2).
Stop-and-keep and Quit wait for finalization; cancelling a pending permission start
cannot create a late recording. The saved hook is ready for W3-3's serial queue.

## Verification

Offline production-writer tests verify canonical folder names, schema/permissions,
recording→saving→saved scanner visibility, duration/playability and capture-byte
preservation. Transactions reject unsafe links and keep titles/notes/revisions.
Hosted UI tests render record-first.png (1120×720, first-record shared fixture),
check Not now and preference persistence, then use a DEBUG-only input driver that
feeds the real session/sink/metadata/controller from RAM. It opens no devices and
requests no permissions, verifies live meters and Stop, and makes Saving observable
with a deterministic finalization stall. Test roots/preferences are isolated from
the user's Library. Release builds contain no hosted recording driver.

Local fixture app/UI runs are now explicitly authorized while hosted CI billing
is unavailable. Real microphone/system-audio validation remains outside these
device-free fixtures. No OS consent is granted by development tools.

D7 disk protection uses the larger of 1 GiB or 2% of the volume as a reserve.
Before Record, a conservative three-channel PCM rate gives an immediate warning
below ten minutes. During capture, actual file growth gives the current write rate;
below thirty minutes, a warning appears without an action and one menu-bar notice.
At the reserve, capture stops and finalizes, retaining the audio and showing the
catalog's stopped-to-keep-space line. The hosted fixture can inject free/total bytes
only while the existing hosted-only RAM-input mode is enabled; it never fills a disk.

## Recording comfort (W4-1)

The pushed Recording page uses the sink's real source peaks and a monotonic clock.
The microphone warning starts after 20 seconds below the silence threshold; Check
opens the existing macOS Sound settings pane. Browser fixtures show the approved
voice-count line; native capture shows the existing computer-sound caption. Source
changes remain disabled until UX11. The browser control broker is still UX10.

Title and line notes write only app-owned meeting.json. First non-whitespace input
pins a note's time; later edits, inserted lines and deletions preserve the times of
existing notes. Debounced actor writes use generation tokens, flush on leaving the
page and before Quit, and preserve unrelated metadata. A write exceeding the
reader's 1 MiB metadata limit leaves the previous file intact.

An app-lifetime watcher keeps captures/transcription discoverable with the window
closed. MenuBarExtra exposes the timer, real meters, Stop Recording, Add a Note…
and Open Cassini. The no-sleep caption appears only while the actual IOPM idle-sleep
assertion is held. RegisterEventHotKey owns only Option-Command-R, without keyboard
monitoring/Accessibility permission. Shortcut registration is released on shutdown;
the power lease is released when capture stops. A label task updates the menu-bar
clock without TimelineView, which caused a launch-time update loop on macOS27.

The Debug `--recording-comfort-self-test` requires the explicit hosted/local test
opt-in plus the isolated RAM-input flags. It verifies real registration, IOPM
acquire/release, controller/sink/metadata writes, note times, 20 real seconds of
silent-mic detection and Stop/Saving. It does not claim Finder keystroke delivery.
XCTest separately covers the real menu actions and global start/stop from Finder,
and exports recording.png plus recording-menu.json in ux-boards.

With `CASSINI_LOCAL_WORKFLOW_TESTS=1` and the existing screenshot fixture flags,
the recording board can render its own NSView to PNG on stdout as JSON. It reads
only the shared fixture and captures no desktop pixels; this is a local layout
render, separate from XCTest's actual-window screenshot.
