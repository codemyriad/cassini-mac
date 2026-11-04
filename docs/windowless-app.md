# Reaching Cassini without a window (D41)

When automatic browser recording is on, Cassini displays its monochrome template
glyph in the menu bar. The idle menu shows the shared readiness line and offers
Open Cassini, Settings… and Quit Cassini. Settings > Recording contains
Show Cassini in the menu bar, initially on. Turning it off hides only the idle
item; it does not disable automatic recording or hide a recording.

One MenuBarExtra changes between idle and recording, avoiding two competing
items. Active capture always uses the existing red dot and timer, including
browser-only and system-audio-only capture. Its menu retains Stop and Open,
followed by Settings and Quit. Quit follows the normal application termination
path: the default Stop and keep it choice drains and saves all recordings before
exit. Keep recording retains the existing explicit background choice; Escape
cancels Quit and leaves the windows visible.

Cassini remains a regular Dock application. A Dock/LaunchServices reopen event
with no visible window opens the Library, and closing the last window does not
quit the application. No extra microphone stream is opened for visibility.

Scene-opening actions have non-nil defaults and are refreshed from the Commands
environment, independently of LibraryView. Cold windowless processes can open
the Library, Settings and legacy viewer. Normal launch restores the Library if
no content window was restored. A minimized window is left to AppKit to restore,
preserving its meeting and search state. Quit activates Cassini and brings its
confirmation parent forward, including when another app owns the foreground.

The menu's content and label observe both capture owners in their own View
bodies, so idle → recording → idle updates while the same item stays inserted.

## Verification

Hosted `LibraryBoards` UI tests exercise the real Settings preference and menu
bar item, close every window while automatic recording is on, reopen from both
the idle menu and a real LaunchServices reopen event, and verify the preference
survives relaunch. A generated RAM capture checks that the recording item stays
visible when the idle preference is off, Settings remains reachable without a
Library window, and the menu's Quit / Stop and keep it leaves completed, nonempty
audio files. These cases use private fixture preferences and generated buffers,
with no audio devices or browser profiles.

Review regressions cover a fresh process with its initial Library scene
suppressed (including no idle item), Dock and both Open actions before a Library
view mounts, generated unattended capture, in-place menu transitions and
minimized meeting/search preservation. Finder-owned click coordinates exercise
Quit without XCTest activating Cassini first; actual focus, Escape cancellation
and Return/save are checked for both a background sheet and a windowless dialog.
The prior Window > Library relaunch workaround is removed from the D41 test.

Mac QA should repeat with the signed app: use the actual Dock icon and idle menu
with all windows closed; test idle visibility off/on and persistence; then test
microphone, system audio only, companion only, and two concurrent browser
meetings. The recording indicator must remain visible in every case. Quit from
the recording menu, choose Stop and keep it, reopen and confirm all audio was
kept. Repeat with Keep recording and Escape to check their distinct behavior.
