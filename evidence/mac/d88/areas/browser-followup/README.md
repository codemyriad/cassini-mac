# D88 browser control follow-up

Base: `89c568bca3528417a74888720f0379103273138d` (#210 merged).
Seven remaining assertions replace elapsed-silence success with ordered pipe
output, retained connection state or EOF. Production source is unchanged.

| Conversion | Positive completion | Real production mutation |
| --- | --- | --- |
| Stale UI key leaves old peer idle | Pong receipt then virtual-clock ping | Include superseded peers when draining/issuing capture stops |
| Reconnected stopped capture cannot restart | Ordered ping barrier | Drop the capture's remembered call context |
| Disconnected Stop All cannot restart | Ordered ping barrier | Omit remembering unbound starts in Stop All |
| Held Start settles once | Ordered ping barrier | Omit reported-capture auto-attempt tracking and duplicate-start guard |
| Legacy hello is never timed out | Assert the connection still has heartbeat state after 300 virtual seconds | Force hello negotiation; separately remove inbound capability gate |
| Later legacy frames cannot arm pings | Tick after accepted inventory and status; requested Stop must be first output | A status wrongly negotiates heartbeat for later frames |
| Heartbeat loss closes the pipe | EOF | Replace EOF with timeout |

The legacy test fails immediately if its connection was removed, before waiting
for an impossible inventory reply. It then advances the manual clock after
each later accepted frame, so a heartbeat armed by those frames really emits
before Stop. Requested Stop fences the ordered writer. Four heartbeat-capable
peers instead acknowledge a pong after reconciliation; advancing the injected
clock produces their next expected ping. Every receive/expectation timeout fails.

The original six synthetic frame-injection proofs were rejected in review and
are replaced. No current mutant emits a fabricated output frame or checks a
fixture clock constant. Eight committed patches change actual registry,
heartbeat or EOF behavior; `replay.py` applies each with
`git apply --unidiff-zero` and reverses it in `finally`. The additional late
status-renegotiation mutation passes the reviewed test at `4b5feff`, then fails
the corrected ordered Stop assertion. Initial negotiation and inbound-gate
mutations fail retained-liveness assertions without expectation timeouts.

25 XCTest cases pass before, after and restored; eight mutants compile and fail
behavioral assertions. See `validation.md` and `current-main-receipt.json`.
Full logs: `~/coordination/evidence/big-mac-d88/next-ipc-agy-review/`.

Replay with Xcode 16.4 selected and SDKROOT set, under heavy-run:
`D88_EVIDENCE_DIR=/tmp/d88-ipc-replay ~/bin/heavy-run python3 evidence/mac/d88/areas/browser-followup/replay.py`.
The script archives the pinned baseline into private scratch, applies the three
current test files, verifies the rejected old EOF check and the reviewed
legacy-test gap, then checks every real mutant independently and restores.
Build and test hang guards remain separate failures; neither can count as a
mutant assertion. The runner also requires executed XCTest cases on every run.
