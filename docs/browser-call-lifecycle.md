# D33 call lifecycle adoption

Shared input: protocol merge
`bb13da92fa8c3192bb6d9b8444acd3197c772d62`, unchanged extension 0.2.2.
The reviewed snapshot is vendored verbatim. No shared extension patch or store
package belongs in this app change.

The per-session `BrowserCallLifecycle` uses the shared 2-second call-end grace
and 120-second browser-return grace. Closed-tab evidence is sticky. The return
deadline is checked before accepting renewed audio; another tab and an absent
PCM transport cannot restore a source. The device owner supplies the actual
source, so failed fallback or restoration staging cannot silently change it.
The production value type passes all 15 unchanged shared vectors (55 steps).

The reader accepts browser restoration and known terminal reasons without
overwriting the last selected source; later events after end are ignored. The
writer reserves the last of 1000 event slots for Stop, finalizes accepted PCM,
then checkpoints one end at or after every known track/prior-event boundary.
Repeated Stop preserves the reason and bytes. An unpublished I/O failure gets
one bounded attempt to persist an error end; a published end stays immutable.
Counted gaps keep their classification and do not turn user Stop into error.

This adoption is in progress. Before enabling `keepOnNavigation`, the app must
parse capability-scoped `pageState`, preserve legacy peer behavior, integrate
fallback/restoration with real track transactions and producer loss timestamps,
and thread terminal reasons and the stop timeline through Stop, disk failure and
Quit. File-only CLI checks cover the actual reader/writer and new tests typecheck;
the complete app/SDK suite and real native/browser stop paths still need hosted
proof. The standalone policy alone does not prove those paths.

Required hosted integration checks include same-folder restoration, The others
off, two independent captures, native staging failures, deadline-boundary return,
closed tabs without computer-sound fallback and durable terminal-event timing.
The standalone policy/vector check is preparation, not product completion.

## First app integration milestone

The owner claims its end trigger before asynchronous native/browser drains,
using a lock that never waits for file I/O. A later generic browser Stop, Quit or
second caller cannot change it; real I/O failure can still produce the required
error end before publication. Broker finalization remains shared, and accepted
PCM tail boundaries extend the earlier trigger time. Owners not yet published to
the UI retain the original monotonic clock. User Stop, disk reserve, input error
and app Quit are now threaded from the app; page-derived reasons are supported
on capable Stop commands. Existing span drains can use the reserved event slot
without admitting a new source or selection at999 events.

pageState parsing is scoped to page-state-v1. Missing remains unknown; legacy
peers ignore this optional metadata. Closed evidence and its original local
observation time survive stale present snapshots. Deferred Stops retain their
first reason. The writer and readers validate restored against selected
system/missing or system/lost history, plus a new active browser span on write.

Still unfinished: using the observed page state in LiveCapture's two-second and
120-second timers, transactional system fallback and same-transport restoration,
The others-off restoration gating, and hosted product integration/failure tests.
keepOnNavigation is deliberately not sent yet; a regression test enforces that
until those paths are integrated. This is a draft, not a completed D33 rollout.
The bundled snapshot remains0.2.2, so equal-version installation/release sequencing
still belongs to the coordinator before distribution. No store package/upload.
