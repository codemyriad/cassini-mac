# Recording spectrogram

The implementation follows `cassini-spectro-v1` in the coordination repository,
`ux-draft/spectro/README.md`. It adds no capture, network connection, permission
probe, silence decision or accessibility announcement.

`RecordingSink` offers admitted immutable S16 PCM after releasing its admission
lock. A bounded bootstrap retains the first visible input until the writer has
published the actual recorded span identity and selection-trimmed start. A staged
input cannot deliver readiness samples before selection commits. Closing the last
view immediately clears these private bootstrap buffers. Browser PCM uses the
same admitted slice and actual span clock as `OwnedBrowserCapture`.

`SpectrogramSession` owns a serial utility queue, a one-second/64-packet input budget per
source, per-rate vDSP transform workspace and independent lane selection. Tracks
keep history when not selected for FFT. The lane sums linear power before the
shared logarithm, release and quantisation. Visibility generations discard stale
queued work while retaining its reservations until the queued PCM is freed; the two-lane mailbox is bounded to 64 columns per lane.

One `RecordingSpectrogram` serves a capture's pill and both page rows. Native
views share 52×32 and 202×64 IOSurface banks. New columns and two guard columns are
written under one surface lock. Core Animation scrolls two cropped texture layers
per lane. A public CALayerDelegate display callback invalidates contents; the
spec's illustrative `setContentsChanged()` is not a public macOS API. Display links
follow window visibility and use 30 Hz for the pill alone; reduced motion uses a
column-rate sweep timer. Stop disconnects both clocks and freezes/fades the image.
The existing AC level remains the source of silence warnings and accessibility.

## Verification

The Swift Testing suites exercise real vDSP against both unchanged shared
vectors, including the DC-offset JFK input, and route S16 through the actual
session at 4096 and 8192-frame chunks. Other tests cover power sums, frame grid,
gaps, overlap, bounded queues, top-three selection, hide/reopen, palette, wrap,
reduced-motion packing and actual native/browser committed-span bridges.
Surface packing unit tests use ordinary RAM, without creating a window/surface.

`scripts/build-spectrogram-probe.py` links an optimised standalone harness from
same-build Release SDK objects and the production native renderer source; it
never rebuilds the app or SDK and is never bundled with Cassini. Debug-only app
fixtures are excluded from that tool. `scripts/test-spectrogram-app.py` executes
it only on disposable GitHub-hosted Macs.
It feeds generated PCM through the production sink/file owner and exercises the
production native renderer for 60 seconds per A–E case. Outputs include per-stage
thread CPU, process CPU/delta fromE, frame intervals, late/drop counters, actual
surface allocation, bounded payload bytes, top logs and a Time Profiler trace.
CPU/pacing/late/drop budgets are asserted, not relaxed for the fixture. Drawing
CPU includes the whole main thread, including implicit Core Animation commits;
utility CPU includes delay, release and mailbox work as well as FFT/PCM. After
measurement, current-process-only ScreenCaptureKit screenshots assert that visible
ink disappears after sound becomes digital silence for a whole history window.
This tests repeated GPU-visible updates of the same surface, not just ring counters;
no other app/display, audio input or TCC consent is involved. The CI
Library job retains its existing tests and adds this probe. No device opens.

The payload counter includes native surface allocation and bounded raw image
storage, but excludes framework/object allocation overhead. It is not an
Allocations measurement. Actual device capture, full allocation accounting,
WindowServer work and visual review of light/dark, reduced-motion, dropout,
source-switch and concurrent-session states require separate hosted/QA evidence.
A passing analysis-only CPU benchmark does not establish the rendering budget.
Do not run the view probe or screenshot/app/device tests on the user's desktop.

Hosted images enable Reduce Motion by default. The probe temporarily changes the
real hosted system preference for normal-motion pacing and restores its original
value afterwards. B also exercises the real preference in both directions: a hosted XCTest driver
changes the actual System Settings control and restores focus to the probe. The
probe requires a real NSWorkspace notification, its real getter and a renderer
clock transition. There is no synthetic notification or renderer-mode override.
Failed lifecycle checks preserve partial metrics for diagnosis.

After timing, B retains own-window images for the silent warning, dotted Others
off, actual PCM dropout/return, dark appearance, Reduced Motion and stopping.
The dropout advances the source clock while withholding callbacks, so the actual
recorder and analysis history see the discontinuity.

A separate invocation with MallocStackLogging captures live allocation sizes and
backtraces before and after detaching views, using heap and malloc_history. It
does not run during CPU measurement and saves no heap contents or raw memgraph.
These records supplement the payload counter; they are not a payload-only
claim that full view allocations meet128KB.

The browser ownership regression holds back the first control status until after
owned audio is stopped. CaptureCollection retains that Stop intent, ends native
input immediately and sends the targeted browser command once the capture's exact
control identity arrives. The normal browser flush deadline still applies while
that identity is pending; another meeting is never used as a fallback target.

The display delay observes the actual20ms column slot, rather than the FFT
centre later within that slot, and display-link requests use the current frame
timestamp. A deterministic continuous60Hz/4096-and8192-packet test retains its
original failing evidence and checks no steady-state early releases. AC history
is copied in bounded contiguous runs with Double reductions; the real FFT removes
vDSP's factor-two amplitude explicitly and passes both unchanged goldens.
Visibility membership is updated synchronously by view/window notifications.
Owned-layer actions are disabled while AppKit batches the implicit transaction at
its normal frame boundary; the display callback does not query window occlusion
or force an explicit transaction. One parent layer scrolls each lane's two fixed wrap textures.
These changes need a fresh hosted measurement; local analysis-only savings do
not establish the native rendering budget.

E1: the native probe subscribes to rendered-column, visibility, real workspace
and Core Animation completion events. Silence/off states wait until their actual
sample/selection boundary replaces the visible four-second history; dropout
length is defined by producer sample positions. No test sleeps or polling delays
synchronize these transitions. Observer hooks exist only in the standalone probe
build and do not scan columns during CPU measurement. The sixty-second CPU run
ends on a real producer progress event after the measured interval; this physical
performance measurement cannot use a virtual clock. Every timeout only fails a
missing event, with the transition's name, and cannot make an assertion pass.
