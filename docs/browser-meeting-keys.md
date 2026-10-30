# Meeting identity during a companion reconnect (D43 follow-up)

A meeting's UI key and a native host's FIFO connection ID are separate. The
registry assigns each tab its UI key once, and every issued command retains its
physical `connectionID`. A replacement host of the same kernel browser instance
inherits keys for overlapping tab IDs. Profiles have disjoint tabs. A different
process start time inherits nothing.

A released host's meeting list remains visible as unreconciled for at most ten
seconds, preserving Retry and microphone choices while discovery returns. It
cannot issue commands or make the Browser settings show Connected. Returned tabs
replace the released entries individually. If a restarted worker first reports a
new tab and starts a command there, a later overlapping old tab never re-keys
that new tab or its in-flight request. No command is moved to another FIFO.
Released hosts are capped at128; per-host alias maps are trimmed beyond512
entries to current discovery, capture and pending-command tabs.

When an identified host disconnects with an unacknowledged Start, the registry
waits up to ten seconds. It never resends that Start. A replacement's recording
status can settle it successfully only for the same browser instance, stable
tab key and exact meeting URL, with a capture ID. Empty early status is not a
failure. At the original deadline, or known browser exit, it fails once. A
replacement arriving before the old disconnect follows the same rule. A buffered
successful Start from the old host also protects the returning call from a
second Start; a failed acknowledgement does not. Explicit
service shutdown settles outstanding reconnects immediately.

Outcomes retain the original UI key and automatic/manual classification. The
driver publishes the new state before delivering completions. It drains a
separate completion queue after each mutation, so simultaneous expiry across
profiles does not discard completions beyond the128-entry diagnostic history.

Only explicit user Stops persist as suppression across connections. Automatic
stops and acknowledged failed Starts are still not learned. The original URL
binding rules from [browser-user-stops.md](browser-user-stops.md) continue to
apply: a new capture reported before its meeting address is known cannot borrow
an old alias's address. The shared protocol, extension pin, process isolation,
audio ownership and FIFO deadlines are unchanged. D33 call-ending policy and
native fallback grace remain their separately queued work.
