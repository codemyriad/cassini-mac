# Explicit browser Stops across control reconnects (D43)

The native host records the parent browser's PID and kernel start seconds and
microseconds in the private peer.json. Shell/XCTest parents are not identified
as browsers. The start time prevents PID reuse from inheriting an earlier Stop;
profiles sharing a browser process remain separate through their tab IDs.
The shared extension/audio protocol and its pin are unchanged.

The registry keeps only explicit user Stops across control connections, keyed
by browser instance, tab and the exact UTF-8 meeting URL. Command attempts and
automatic stops stay per connection. Explicit Record overrides its call's Stop.

Stop memory is bounded to256 entries. Ten minutes of absence expires an entry;
the prior live inventory protects a still-present long call. Expiry runs before
an incoming inventory is applied. Every inventory compares URLs, including SPA
changes without an empty intermediate inventory. A returning tab is reconciled
within10 seconds of either the connection or the most recent Stop/report, so a
fresh Stop on an old connection is not discarded as late. Known-dead browser
instances are removed; denied process inspection is treated as unknown.

Capture IDs bind to the original meeting address on the first status, before
registration of the audio owner is required. The association is immutable when
the tab navigates, retained while the app owns the capture and bounded to256
entries. User Stop is remembered before both the command busy/reconciliation
checks and the app's already-saving guard. Disconnected capture Stops therefore
use their original URL. An unavailable original URL is never a wildcard.

An overlapping newer connection supersedes a draining old connection of the
same browser/profile. Late old inventories cannot erase a newer Stop, and an
old connection cannot regain auto-start authority if its replacement disconnects.
No issued command is moved to another FIFO or replayed. The subsequent
[meeting-key follow-up](browser-meeting-keys.md) separates UI keys from physical
connections and adds a bounded lost-Start reconciliation window.

Local verification uses actual source with focused file/IPC tests, plus the
same two regression assertions against an origin/main snapshot: both fail on
main and pass with this change. Hosted background registration additionally
requires PID/start metadata from the real Chromium native host and validates
the PID against the running Chrome for Testing process. No recording is needed.
