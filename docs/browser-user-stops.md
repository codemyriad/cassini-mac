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
changes without an empty intermediate inventory. Initial discovery may take
longer than10 seconds without deleting an unexpired exact Stop. Only a tab that
was previously present and then absent gets a10-second disappearance window;
a fresh Stop still wins over an older absence marker. Known-dead browser
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
Lineage follows observed tab overlap, including a bounded history of256 tabs
per live connection. It survives empty inventories and late discovery. A newer
connection which has not reported any tabs remains ambiguous and prevents old
links from erasing Stops. Once its disjoint profile is identified, it cannot
veto another profile's verified absence or navigation, even if it later reports
an empty inventory. No issued command is moved to another FIFO or replayed.

### Meeting keys and lost Starts across a worker restart

A meeting's UI key is separate from its physical connection; every command
carries its `connectionID`. A tab's key is committed once per connection, by
discovery or an issued command. On first discovery it inherits the key of the
newest earlier link of the same browser instance that reported the same call on
that tab: the same `callGeneration` for a `multi-stream-v1` peer, the exact URL
only for an older peer. A different call, process or profile tab gets a fresh
key, and a late old tab never re-keys a tab whose command was already issued.

A disconnected identified link stays listed, unreconciled, for at most ten
seconds so Retry and microphone choices survive; it never issues commands. Its
unacknowledged Starts are held, never resent, and settle once as successful
when a newer link of that instance reports a recording capture with an ID for
the same tab and call (a different `callGeneration` never settles it). They
fail at the deadline, on known browser exit or at service shutdown. A buffered
old success also prevents a duplicate Start; failed Starts and automatic stops
are still not learned. The driver drains a separate completion queue, so many
simultaneous expiries cannot exceed the 128-entry outcome history. At most 128
released links are kept; per-link key maps are trimmed beyond 512 tabs.

Local verification uses actual source with focused file/IPC tests, plus the
same two regression assertions against an origin/main snapshot: both fail on
main and pass with this change. Hosted background registration additionally
requires PID/start metadata from the real Chromium native host and validates
the PID against the running Chrome for Testing process. No recording is needed.

Review fixes retain unretired capture identities across disconnect, even before
an audio registration reaches the app. Stop All records their original call
identities and outstanding Start contexts, including superseded peers, while
wire commands still target usable connections only. Unknown capture-ID Stops
stay unresolved until a matching ID obtains a trustworthy call association;
they never borrow the tab's current URL as a wildcard. All pending-intent caches
are bounded to256 entries and expire after10 minutes when no longer retained.
Authoritative Stop results/status retire capture presence, so a later Stop All
does not learn historical completed captures. Older peers cannot erase Stops
once their own replacement has reconciled (or while a newer empty connection
is still ambiguous), rather than whenever an independent profile connects. Only explicit
Record, never an automatic start, can override its call's Stop.

The follow-up profile regressions stop and acknowledge a call in profile A,
connect independent profile B in the same process, then verify both an11-second
absence and navigation away/back let A record again. They also cover B returning
to an empty inventory and replacement ownership through earlier observed tabs.
The requested two-profile cases fail onf0627e9 and pass with the lineage fix.

Retirements caused by discovery keep a tombstone tagged with the removing
connection and its inferred lineage. If delayed tab overlap proves that link
was superseded, its unexpired retirements roll back before the replacement's
inventory is applied. Provisional lineage merges retag tombstones too. This
handles a replacement initially reporting only another tab while the old link
reports stale navigation or absence. Active Stops and tombstones share the256
entry budget and the original expiry clock. Explicit Record removes both;
rollback never reverses it or revives an expired Stop.

D43.2 retains the disconnecting owner's lineage and observed-tab history while
its retirement tombstones remain. A later overlapping inventory can therefore
prove supersession and restore the Stop even after the old peer is gone.
Summaries are scoped to the exact browser instance and connection order; they
never appear as live peers or discoveries. There are at most256 summaries with
at most256 tab IDs each, inherited from the existing bounds. Resolving, expiring
or explicitly overriding the tombstone releases its summary. The original
10-minute expiry and shared256-entry Stop/tombstone budget still apply.

Rollback also keeps the connection-order boundary from when the retirement
was observed. Only a replacement already connected at that point can prove
the old report stale. An ordinary later reconnect after an authoritative
navigation must not resurrect the previous call's Stop.
