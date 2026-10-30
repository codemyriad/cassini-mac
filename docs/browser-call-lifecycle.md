# D33 call lifecycle adoption

Shared input is protocol merge
`bb13da92fa8c3192bb6d9b8444acd3197c772d62`, vendored verbatim with extension0.2.2.
There is no extension patch, store package or upload in this app change.

Capable independent Starts opt into keepOnNavigation. Each recording retains
its own folder, original PCM transport, origin and microphone choice. Legacy
peers keep their existing behavior, including the30-second return grace. A
management reconnect alone does not create a new audio owner or recover a dead
native transport. Release/version sequencing for equal-version0.2.2 companion
snapshots remains coordinator-owned before distribution.

The per-session BrowserCallLifecycle uses the shared2-second call-end grace
and120-second return grace. Browser-confirmed closure is sticky and stops after
2 seconds without opening computer sound. Navigating/absent pages can request
computer sound after2 seconds. A present page with zero sources ends the call
after2 seconds outside pending navigation. A positive same-tab return acknowledges
that navigation even if restoring its selected source fails. A later hang-up
therefore follows the normal call-end rule rather than the return grace.

Timers use the producer's loss/page observation stamps. A delayed first observer
checks the120-second deadline before accepting a returned page. Each loss stamp
is acknowledged once; keeping a working fallback after a failed restoration
cannot restart an old deadline. Fresh PCM on the original owned browser path
can bridge a brief missing management inventory; it never overrides explicit
navigation/closure or a dead audio transport.

## Input transactions

Managed loss defers system-input admission to the policy. The existing bounded
StagedNativeWriter prepares an authorized computer-sound driver and its actual
buffers before its writer becomes active. A failed candidate cannot publish a
system event or stop the working microphone. Retry remains scoped to that side.
An actual system event is published only when its first PCM is admitted.

Restoration requires fresh PCM on the original transport. Format announcements
alone are insufficient. PCM preceding the observed return cannot justify switching off a working
fallback. Later speakers get their own spans even if their first PCM follows
the initial restoration. A network recovery can reuse its source identity with
a fresh span. The working system sink pauses and drains without ending its file.
One metadata checkpoint ends all system spans, starts fresh active browser spans
and publishes browser/restored together. The cutover includes time spent waiting
for the drain; earlier buffered browser packets remain excluded. The microphone
continues on its original writer and clock throughout.

A rejected restoration resumes the exact previous system writer/timeline.
Track-limit and real private-directory write failures exercise this path. A
post-checkpoint sync failure follows the already-published source and retains
its I/O diagnostic. The others off stays off; explicitly turning it back on
uses a ready browser source without unnecessarily restarting computer sound.
A return before any system PCM resumes the browser without inventing a restored
from-system event. Concurrent meetings have independent policy/input owners.

## Terminal events and validation

The owner claims an end trigger/time before asynchronous native/browser drains.
A later generic browser Stop, Quit or second caller cannot rewrite it. Accepted
PCM tails and prior events extend the final boundary. The writer reserves the
last of1000 event slots for end; existing spans can drain at999. Repeated Stop
preserves bytes/reason, and readers ignore later events after end. Actual I/O
failure gets the bounded unpublished-error behavior; counted gaps retain their
classification. Shared reader/writer restoration constraints remain enforced.

Local validation uses source, file/FIFO and generated-buffer checks only. The
literal15 shared policy cases pass unchanged, together with producer-delay,
rollback, WAV-tail, selection, dead-transport and concurrent-owner tests.
The hosted app proof now requires original-transport restoration, The others-off,
closed-tab/no-new-system and durable120-second-end reports from the actual app
and bundled native messaging executables. It uses generated native inputs.

This PR stays draft pending the full hosted gate and a dedicated real Chromium
navigation/reload test against this app (not only the standalone policy or fake
control client). The earlier83 Stop-memory fixes must be adopted when they land;
its automatic/user Stop distinction must survive the rebase. No self-merge.

Known remaining product work before this draft is ready: revalidate/cancel
pending source changes when page state changes during authorization or drain.
In particular, a returned browser must not wait indefinitely behind an unresolved
system-permission request, and a newly navigating/closed page must invalidate a
staged restoration before source commitment. Add those interleavings to the
product proof, then run the dedicated real Chromium reload path. These are
tracked implementation requirements, not a claim that the rollout is complete.
