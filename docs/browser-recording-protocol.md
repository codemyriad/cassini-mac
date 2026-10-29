# Browser recording protocol

The normative, cross-platform v1 contract now lives in
[browser-protocol/SPEC.md](../browser-protocol/SPEC.md), alongside JSON Schemas, executable
raw-JSON vectors and the exact shared extension snapshot. See the
[snapshot instructions](../browser-protocol/README.md) for SHA verification and adoption.

Mac implementation: `Sources/CassiniRecording/BrowserProtocol.swift` and
`Sources/cassini-browser-host/main.swift`. Native host ID: `com.codemyriad.cassini`.
The app-owned browser host and native recorder write independent `Recording-<UUID>` folders
into the selected Library (initially `~/Music/Cassini`). The scoped in-app Connect action
installs the fixed browser/control host pair. See [the companion implementation](browser-companion.md).

Verification scope and hardware limitations are in the companion implementation notes.
This raw recording-session format does not imply transcription or Cassini Opus export.
