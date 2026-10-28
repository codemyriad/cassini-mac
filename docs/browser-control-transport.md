# Browser-control transport groundwork

`CassiniBrowserControl` and `cassini-control-host` provide the private app/native-host
transport for UX10. They do not yet install browser manifests, run an app broker,
start recordings, or appear in Cassini.app. The shared control v1 messages remain
unchanged; the independent-session capability and recording writer follow separately.

The sandboxed app's existing Music-directory access can support a private FIFO
broker without adding a network entitlement. A separate, disposable XPC experiment
proved that primitive on the development Mac; the production app integration still
needs its own signed, fresh hosted test. The Unix-socket alternative was denied by
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
