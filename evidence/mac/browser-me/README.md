# Browser-owned Me (#259)

Modern separated calls advertise sender-me-v1 and receive captureLocal:true on
Start and resumeCapture. Missing or different capability strings receive false.
The initial native Start's missing/false captureLocal retains OS Me for older
companions; true makes Me browser-owned. Malformed flags are refused before
files or inputs are created. Verified admission retains this choice and resume
keeps the original owner's immutable mode (the native resume omits the flag).
Native Record and D74 mixed routes still own native Me. Resume negotiates the
capability AND this immutable owner mode: D49 stand-ins and legacy sessions
never start a browser local sender after a companion upgrade.

Selected local PCM (including mute zeros) keeps Me-only alive through MV3
control restarts and split status-before-inventory reconnects. Explicit page
loss still saves a problem. Others restoration requires non-local PCM: a local
sender arriving first neither pauses fallback nor satisfies the writer's
othersSource browser transition. A disconnected Me-only choice is rejected
before pausing Others and never offers macOS microphone settings.

Both lifecycle admission and the native span writer reject hardware Me for a
browser-owned session. Browser local PCM follows Me's selection, ledger,
trimmed spans, per-source AC meters and analysis lane. Loss ends its span and
clears its meter; Me+Others leaves a gap until returned browser PCM is admitted.
Me-only browser loss instead saves a capture problem, including before any PCM;
the app retains that diagnostic meeting rather than discarding an empty folder.
Verified admission can deliver pageGone before the queued browser-loss callback,
so finalization also honors that immutable terminal intent. Normal empty user
cancellations retain their existing discard behavior.

Protocol pin: merged156b40c314e7acf4e75d53c2fbc77fdae8deacc4, companion0.2.27,
hook2. The canonical vendor tool updates both shared snapshot and installed
extension; verify.py validates the Git-tree proof and every installed file.
Historical producer traces remain frozen. The pinned source implements and tests
screen-share exclusion, sender/clone deduplication and mute/unmute privacy.

GNOME comparison: merged6de7a0440d71947e6e21e0bbdb5b8e78dc8b4ad3.
Both apps negotiate sender-me-v1, preserve missing/false legacy native Me, keep
modern ownership immutable on resume, retain Me+Others reload gaps and save a
problem on Me-only loss. GNOME's latest local meter is one value; Mac takes the
maximum of fresh per-source local levels. Mac's independently centered 100 ms
AC windows reject stereo DC only after an actual complete-window timestamp.

Validation and public receipts: results.json. replay.py applies every committed
production patch, requires executed XCTest behavioral assertion failures (never
a timeout, crash or compile failure), restores exact source bytes in finally,
and requires the restored focused suite to pass. Run under ~/bin/heavy-run with
Xcode16.4, SDKROOT, verified CASSINI_OPUS_ASSETS and an external
BROWSER_ME_EVIDENCE directory. BROWSER_ME_BUILD may reuse a private scratch path.
No simultaneous build may read the sources while mutation replay runs.

The native app self-test uses framed production hosts with synthetic local PCM,
requires zero OS microphone authorization and proves empty Me-only problem
retention. Real Chromium return and shared live-folder tests require fresh local
spans after reload and use a different 660 Hz native fixture tone from the 440 Hz
browser sender to detect a wrong route. Native runtime is run by isolated CI;
no local browser, real recording, microphone or playback device is opened.
