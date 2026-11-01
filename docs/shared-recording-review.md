# Shared recording PR review

Mac is the second implementation of cassini-browser-protocol. GNOME owns the discovery,
Jitsi deduplication and waveform-overlay work assigned in DIRECTION-2026-10-27.md.

For each upstream G2/G4/G5 PR:

1. Fetch and record the exact head SHA; inspect runtime, schema, vector and fixture changes.
2. Vendor that SHA into an isolated Mac worktree. Verify the commit/tree and installed bytes
   with `python3 browser-protocol/verify.py --pinned BrowserExtension`.
3. Build the Mac host and run the upstream vectors against it. If the PR adds host semantics,
   use the corresponding Swift implementation in the same review window.
4. Run shared unit/topology tests and Mac synthetic/loaded-extension/tab-capture scenarios.
   Tab capture needs a real output device, so it is a manual check on a developer Mac. Include new regression scenarios from the PR.
5. Check mute/gating, duplicate prevention, lifecycle cleanup and Chrome 116 APIs. Verify
   page labels remain untrusted and overlays report the audio admitted by the recorder.
6. Review/approve only the tested SHA. If the PR changes afterward, inspect the delta and
   rerun checks affected by it. Merge upstream before updating the app pin.
7. Commit/push the Mac pin and any host implementation together; record CI and evidence in
   /tmp/cassini-recording-coordination/MAC-STATUS.md.

As of the M1 checkpoint on 2026-10-27, no G2/G4/G5 PR is open. Review remains pending receipt;
the existing released pin is 14271ee2118a763325512ec7572a9385ed7709c6.
