# Fresh microphone window at the silence boundary

The reviewed code drained levels at uptime 0, then checked 19.98 and 20 without suspending the MainActor. No fixture PCM could arrive between those reads. The fix waits for at least 800 additional microphone frames per owned recording at uptime 20, then refreshes before asserting silence.

Xcode 16.4 / SDK 15.5, synthetic mono 8 kHz PCM, under heavy-run. The probe extracts the actual app boundary, observation wait, uptime setter, level refresh and silence predicate. It compiles the unmodified production CassiniKit/CassiniRecording sources in a private package, using real RecordingSink admission, AC windows, status consumption and writer bytes. Observable adapters replace app-only views/owners; no audio device is used.

| Case | Result |
| --- | --- |
| Reviewed boundary, DC subtraction disabled | PASS with `[0, 0]` new frames: false-pass witness |
| Fixed boundary, constant DC | PASS with `[800, 800]` new frames |
| Fixed boundary, DC subtraction disabled in real ACLevelChannel | FAIL at silent-at-20 assertion |
| Fixed boundary, no new PCM | FAIL at the failure-only state deadline |
| Fixed boundary, tone plus DC | FAIL at silent-at-20 assertion |
| Restored production source | PASS with `[800, 800]` new frames |

The AC mutation changes `let mean = sum / Double(count)` to `let mean = 0.0` only in the private package. No production metering implementation changes are shipped. The missing-frame and loud-mic controls also enforce that the new gate actually runs and admits a whole window.

Replay with Xcode 16.4 selected and its SDKROOT exported:
`D88_EVIDENCE_DIR=/tmp/d88-mic-review ~/bin/heavy-run python3 evidence/mac/d88/areas/app/mic-dc-review.py`

App source SHA-256: `83dfa4ac450ec670daedc00ecb4f6009ef55d7f9a50878e6d6a0a4a1ba9d3fbc`.
RecordingSink SHA-256: `1408906079fd564f8472ab2f215801235079108a5ad7224286b035a308077ebd`.

Full logs, the extracted Swift program and results.json are in coordination `evidence/big-mac-d88/mic-dc-review/`. The first harness compile lacked two unused browser-level snapshot members; that discarded compile log is retained. The app/GUI integration run remains required on the pushed head.
