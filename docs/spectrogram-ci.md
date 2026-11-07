# Spectrogram measurement policy

The hosted Mac guard policy is D36.2, coordination commit `e0e3124` (2026-11-01), amended by D36.3 (`da65b18`), which raises the Library pill (A) drawing guard to 1.7%, and D36.4 (`aa34676`), which sets the Recording page (B/D) worst frame to 100 ms; p95 17.5 ms stays the pacing guard. These are regression limits for the virtualized GitHub runner. The product target remains about 1% total CPU on real hardware for the Recording page; this PR does not claim a new real-hardware measurement.

| Measurement | Hosted limit |
|---|---:|
| Analysis CPU, percent of one core | 0.8% |
| Drawing CPU, Library pill (A) | 1.7% |
| Drawing CPU, Recording page (B/D) | 3.5% |
| Page frame p95 / maximum | 17.5 / 100 ms |
| Late columns | 3% of steady-state timeline slots |
| Logical view payload | 131,072 bytes |

The lateness denominator is one shared 50 Hz timeline, independent of the number of lanes or selected input tracks: `floor(measuredSeconds * 50)`. A 60-second window therefore permits at most 90 late contributions. Both the raw count and fraction are retained in each report. Missing input, dropped buffers and mailbox overflow still fail independently.

Hidden/minimized/off cases retain zero analyser and display callback work. Reduced Motion retains its specified non-translating sweep: zero display-link callbacks, with analysis and column-only image updates. The actual System Settings transitions and the complete silence/off/dropout/theme/Stop/allocation checks remain mandatory.

The implementation stays on `NSView.displayLink` and the shared IOSurface ring. The rejected CV-clock and other renderer experiments are not bundled. Their numerical evidence is in coordination `D36-MAC-BUDGET-DECISION.md`.

`Spikes/Spectrogram/Budget.swift` is shared by the probe and the pure boundary checker. The checker can run without AppKit, audio, graphics or devices:

```sh
swiftc Spikes/Spectrogram/Budget.swift Spikes/Spectrogram/CheckBudget.swift -o /tmp/cassini-spectrogram-budget
/tmp/cassini-spectrogram-budget
```

Native A–E measurements run on disposable hosted Macs. Each case waits for actual producer progress through its 60-second measurement interval. Time Profiler and allocation diagnostics use separate processes; their overhead never enters those CPU/pacing windows. Drawing includes all main-thread CPU so implicit Core Animation work cannot move outside the measurement. Reports also retain process CPU and its delta from the disabled baseline E. Sampler backtraces are diagnostic evidence, not a substitute for the counters.

## Delayed fixture wakeups

The generated source is an integer sample clock, not a finite hardware buffer.
The old producer kept only ten chunks after a delayed callback and advanced its
frame index over the rest. In the archived B failure, the skipped-frame counter
was 57,344. An injected replay with a 12-chunk initial callback and a later
22-chunk callback reproduces that count: two chunks skipped before source
creation and twelve after it. The latter insert 1,024 ms into each native lane.
Together with the deliberate 2,048 ms Others omission, the real RecordingSink
reports 4,096 ms. Its accounting was correct.

Catch-up now offers every completed chunk in bounded ten-chunk batches, yielding
and immediately rearming while behind. The skipped-frame diagnostic is derived
from sample position minus actual produced frames. The exact existing finish
expectation, dropped-input checks, late-column limits and all performance guards
are unchanged. The injected clock regression and the real RecordingSink replay
both reproduce the old counters and verify 2,048 ms with zero skipped frames after
the fix. They use no clock sleeps, audio device, window or graphics context.

The native A–E job consumes the shared Release objects and therefore explicitly
waits for the Release producer, both from CI and standalone dispatch. Changes to
analysis, PCM admission and the fixture clock select this native consumer.
