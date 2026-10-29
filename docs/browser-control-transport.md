# Browser-control transport groundwork

`CassiniBrowserControl` and `cassini-control-host` provide the private app/native-host
transport for UX10. They now connect to the per-meeting app broker described in
[browser-companion.md](browser-companion.md). The bundled scoped setup service installs
the fixed manifests; the independent-session capability keeps audio owners separate.

The sandboxed app's existing Music-directory access can support a private FIFO
broker without adding a network entitlement. A separate, disposable XPC experiment
proved that primitive on the development Mac; the production integration uses the unchanged app profile and adds hosted signed-app
checks with RAM-only inputs. The Unix-socket alternative was denied by
the sandbox even with a server entitlement. The scope spike is documented in
[browser-setup-spike.md](browser-setup-spike.md).

The broker owns `~/Music/.cassini-browser-control/server.lease`. Each host publishes
a private UUID directory containing two FIFO directions, metadata and its own
kernel lease. Directories require the current UID and mode 0700; files/FIFOs require
0600, a single link and the expected type, opened without following a final symlink.
Clients stage the directory before publishing it with one rename. The server sends
a private ready frame before accepting control traffic. Browser names are hints;
the UUID namespaces connections, including multiple profiles using the same tab ID.

Each peer has its own reader, ordered writer and bounded pending-byte budget.
Fragmented frames remain intact across polling intervals. A stalled or malformed
peer disconnects independently. Cancellation wakes I/O without closing descriptors
under another thread; the owning I/O task closes them. Broker shutdown keeps its
lease until old readers and writers retire, preventing two servers from consuming
the same pipe. Dead published leases and abandoned staging directories are cleaned
up using only the fixed children of validated private directories.

Native messaging uses a four-byte little-endian length and at most 524288 bytes.
JSON objects are parsed strictly before relaying; duplicate members, non-finite
numbers and non-integer `hello.version` values fail. Normalization preserves number
lexemes and string values. The host emits no fabricated stop message on EOF and
keeps diagnostics off stdout. The production bridge uses framed FIFOs; the
`CASSINI_CONTROL_SOCKET` override is only an NDJSON adapter for the unchanged shared
conformance runner. `CASSINI_CONTROL_PIPE_ROOT` selects generated private roots in
tests. Neither override grants the sandboxed app arbitrary filesystem access.

Run the transport and real host-process tests with:

```sh
swift test --filter CassiniBrowserControlTests
python3 browser-protocol/conformance/control/run.py .build/debug/cassini-control-host
```

These tests create disposable files and processes only. They use no browser profile,
window, capture device, microphone, user recording or TCC permission. The existing
ARM and Intel browser-setup jobs also run them from the shared producer's products;
no second application build or new matrix job is introduced.

## Control state (follow-up)

`BrowserControlRegistry` is value-only state for the app driver. Every peer/tab key
includes the connection UUID. The first standalone status must reconcile existing
captures before explicit or automatic starts are allowed. Empty `sessions` lists
are authoritative even when legacy top-level fields still report a recording.
Start requests always use Separate tracks, opt into independent sessions, turn off
page-local capture and carry the per-session microphone choice. Paths reported by
the browser remain advisory and are never opened or used as writer destinations.

The registry correlates results by request ID; a result containing an old snapshot
cannot resurrect a capture removed by a newer status. It suppresses auto-restart
for the same call after an attempted start or Stop, rearming after discovery removes
the call. Losing management drops discovery and pending commands without inventing
an audio Stop. Native recording lifetime belongs to the recording broker.

The driver must call `drainStops()` after command completions/timeouts. Stop intent
survives a full 128-request window, so stopping 100 pending starts sends an initial
batch and drains the remaining Stops as capacity becomes available. A failed Start
is never blindly resent: it may already have created a capture. The app collection and audio broker connect this state to owned recording lifetimes.

`BrowserControlService` drives that state over the private FIFO server. Its callbacks
run on the service queue; app observers must hop to the main actor. The completion
callback's Boolean identifies an automatic request. A notification is appropriate
only after an automatic Start completes successfully. Commands expire after 30
seconds by retiring their management peer: fresh connection status then reconciles
any recording that already started. This does not disconnect the separate PCM host.
Auto-record starts disabled and is enabled explicitly in Settings > Recording.

The app vendors coordinator-approved shared main `56814d5`, including independent command queues, S-6 events, startup-loss fallback and native-gap metadata. The extension remains 0.2.0 in source; the coordinator owns the store release bump. Canonical extension tests run beside the shared vectors; verify.py checks the installed extension byte for byte and binds the full snapshot to the exact upstream Git commit.
