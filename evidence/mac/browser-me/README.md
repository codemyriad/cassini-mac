# Browser-owned Me (#259)

Separated calls send captureLocal:true on Start and resumeCapture. An owner's
immutable nativeMe flag is false for browser starts. Both lifecycle admission
and the native span writer reject hardware Me for that owner. Native Record and
D74 mixed routes retain native Me. Browser local PCM follows Me's selection,
ledger expectations, trimmed span boundaries and observer lane; loss ends its
span and clears the meter, leaving a privacy gap until browser audio returns.

Browser Me reuses the native sink's independently centred 100 ms AC windows.
The stereo DC test admits 800 frames per channel and requires a completed-window
timestamp before asserting zero; silence cannot pass with an empty meter.
Muted browser PCM remains silence. Per-source local meters never feed Others.

Validation: 394 browser-control XCTest cases and five Swift Testing cases pass;
35 restored focused XCTest cases pass. An additional recording/broker slice
passes44 XCTest and51 Swift Testing cases;57 CI contracts and snapshot integrity
pass. The final native app/Quick Look build passes; native self-test runtime
remains pending CI. Seven committed production mutations
fail executed XCTest assertions: command captureLocal, startup authorization,
selection authorization, native writer admission, local side selection, local
ledger expectation, and DC-sensitive local metering. No mutation is accepted
for a timeout, crash or compile failure. replay.py applies each committed patch
and restores exact source bytes in finally. Run under ~/bin/heavy-run with
Xcode 16.4, SDKROOT, verified CASSINI_OPUS_ASSETS and external BROWSER_ME_EVIDENCE.

GNOME comparison: feat/browser-local-me-capture at97a42f7 gates browser local
sources on Me, trims selected PCM, clears levels on loss/deselection/end and
uses a continuous AC meter. Its native_me compatibility escape also accepts
message.captureLocal:false. Mac's separated owner has no such escape. GNOME's
last-fed local meter is a single value; Mac keeps per-source levels and takes
the maximum of fresh local sources. Both accept a reload gap instead of opening
hardware Me. Current GNOME main still uses the old native-Me default; the
comparison is specifically against the coordinator's feature branch.

Protocol cross-check:0702aff page-capture tests (including display-share audio
and cloned tracks) all21 pass in an external detached checkout. No protocol pin
or vendored file is changed here. The native app fixture now submits synthetic
local PCM over the bundled framed host and asserts no hardware authorization;
its live-folder OS fixture uses660 Hz while the WebRTC local sender uses440 Hz.
No real recording, microphone or playback device is used.

Waits for the protocol pin:
- call-signals-vectors.json nativeStartCorrelation commands0/2 in
  late-automatic-after-manual-same-call and numeric-zero-is-not-string-zero
  still say captureLocal:false. VerifiedAdmissionTests exercises their native
  replies/identity; ControlRegistry/ControlService and D58ResumeOutcome tests
  assert the new true command field independently.
- Shared live-folder test2's old driver/oracle expects native microphone spans
  and two captured browser sources;0702aff expects local Me and three sources,
  fresh local spans after restore, their FFT proof and clock facts (O4–O6).
- Refusal writer cases start-rejected-falls-back-to-computer-sound,
  start-rejected-without-code-falls-back and start-rejected-and-system-refused
  still carry native-Me expectations in the fallback profile. Mac uses the
  noFallback profile, whose cases are unchanged; all its refusal tests pass.

These are recorded dependencies; the old shared oracle is not disabled or
rewritten. The complete change remains a draft, Part of #259, until protocol
merge/pin adoption and exact-head CI/review.
