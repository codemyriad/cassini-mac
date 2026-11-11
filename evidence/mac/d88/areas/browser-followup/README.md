# D88 browser control follow-up

Base: `89c568bca3528417a74888720f0379103273138d` (current main, #210 merged).

These seven remaining assertions replace elapsed-silence success with ordered pipe output or EOF. Production source is unchanged.

| Conversion | Positive completion | Mutation |
| --- | --- | --- |
| Stale UI key leaves old peer idle | Reconciled pong followed by virtual-clock ping | Inject command before pong receipt |
| Reconnected stopped capture cannot restart | Same ordered ping barrier | Inject command before pong receipt |
| Disconnected Stop All cannot restart | Same ordered ping barrier | Inject command before pong receipt |
| Held Start settles once | Same ordered ping barrier | Inject duplicate Start before pong receipt |
| Legacy hello receives no initial ping | Requested Stop is first output | Inject ping at initial inventory |
| Legacy hello survives later inventory without ping | Requested Stop is first output | Inject ping after virtual time advances |
| Heartbeat loss closes the real pipe | EOF | Replace EOF with timeout |

The legacy peer retains its original capability set. After virtual heartbeat advances, observed inventory and recording status lead to an explicit Stop. The first outgoing frame must be that Stop, fencing earlier unwanted pings. Four heartbeat-capable peers instead acknowledge a pong after reconciliation; advancing the injected clock produces the next expected ping through the same ordered writer. Every receive/expectation timeout fails.

Validation: 25 XCTest cases pass before, after and restored; all seven independent mutations fail. See `validation.md` and the individual patches. Fresh current-main proof and source hashes are in `current-main-receipt.json`; full logs: `~/coordination/evidence/big-mac-d88/next-ipc-current/`.

Replay from this checkout with Xcode 16.4 selected, `SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"` exported, and an external output directory: `D88_EVIDENCE_DIR=/tmp/d88-ipc-replay ~/bin/heavy-run python3 evidence/mac/d88/areas/browser-followup/replay.py`. Compilation and execution have separate failure-only guards; a compiler failure cannot count as a mutant assertion. The script archives the pinned baseline, applies these three tests, checks each mutant independently, and restores production source between cases.
