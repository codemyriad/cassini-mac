# Browser recording protocol

The normative, cross-platform v1 contract now lives in
[browser-protocol/SPEC.md](../browser-protocol/SPEC.md), alongside JSON Schemas, executable
raw-JSON vectors and the exact shared extension snapshot. See the
[snapshot instructions](../browser-protocol/README.md) for SHA verification and adoption.

Mac implementation: `Sources/CassiniRecording/BrowserProtocol.swift` and
`Sources/cassini-browser-host/main.swift`. Native host ID: `com.codemyriad.cassini`.
The Mac browser host writes `~/Music/Cassini/Recording-<UUID>`. The app opens these through
an explicit folder picker; microphone/system recordings use a user-selected destination.

Installation, tested paths and hardware limitations are in the repository README.
This raw recording-session format does not imply transcription or Cassini Opus export.
