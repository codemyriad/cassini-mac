# AWS Mac D88 transport discovery / process exit

Base main `9a22168`, Xcode 16.4, AWS Mac M4, 2026-11-10.

Discovery tests now invoke completed discovery passes, keeping orphan/staging
retirement, retained client lease and single-adoption assertions. Broker replacement
waits for the actual final peer retirement and broker-lease close. Idle shutdown
observes entry into the reader wait; host status checks consume termination events.

Partial-frame coverage holds the real FIFO reader after two header bytes. The
healthy peer must round-trip while that reader is held. Advancing an injected read
clock by 350 ms crosses the former 250 ms boundary, then an explicit release allows
the remaining header and body through. Default read clocks, polling, deadlines and
production discovery scheduling remain unchanged.

MeetingTests.swift's transcription progress loop now observes actual committed
sidecar writes and joins the worker through a completion semaphore. The callback
checks the saved mixed-progress bytes before any next publication can replace them.
All retained-tail, final text/count and completion assertions remain. The new optional
callback defaults to empty; normal transcription behavior is unchanged.

## Evidence and limits

- `focused-before.log`, `focused-after.log`, `focused-restored.log`: all 20 framed
  I/O / discovery / host tests pass.
- `before.log`, `after.log`, `restored.log`: 415 XCTest tests (22 inherited asset
  skips, no failures) plus five Swift Testing cases pass. The synthetic worst-case
  recording fixture is included; its reported wall duration is diagnostic only.
- `partial-deadline.patch` / `.log`: reintroducing a 250 ms frame deadline fails
  the real fragmented-write and received-payload assertions after virtual advance.
- The local asset guard skips the real recognizer resume fixture in both baseline
  and changed runs. Its assertions and original guard are preserved; exact-head
  pipeline CI supplies the pinned assets and must pass before readiness.

Runs hold `~/.cassini-heavy.lock` and stage only changed Swift source/tests into
`/tmp/cassini-aws-d88-before`, restoring them afterward. Broad command: `swift test
--scratch-path /tmp/cassini-aws-d88-before-build --jobs 4 --filter
'CassiniBrowserControlTests|TranscriptionMeetingTests'`. The focused filter is
`PipeTransportTests|ControlHostTests|FrameIOTests`. Mutation exits nonzero; restored
source is clean. No GUI or audio device is used.

## Checked bug classes

Reviewed `~/coordination/BUG-CLASSES.md`: 17 checked via completed scans, read gates,
manual clock and exit/write events; 14 checked via complete-frame/partial-frame and
EOF assertions; 15 checked via malformed-host exit status and transport-close paths;
18 checked (base main). 19 pending exact-head CI, including the real pipeline guard.
1–13 and 16 not applicable: no new transcript ordering, format or storage policy.

## Supplemental committed-write proof (15:27 UTC)

The existing offline VAD cache permits a generated-silence publication test without
using recorded speech or a device. `testSidecarWriteObserverReadsCommittedBytesForGeneratedSilence`
reads the real sidecar synchronously from the callback, checks its language/items,
requires a publication and checks final Library state. Recognition must never run.

`sidecar-after.log`: the generated-only test passes with the pinned VAD cache.
`sidecar-before-write.patch` / `.log`: moving the notification before atomic write
fails the committed-file and publication-count assertions. `sidecar-restored.log`:
all 21 focused I/O/host/discovery/publication tests pass, with no skips. These runs
use the shared `mkdir ~/.aws-heavy.lock` wrapper and Xcode 16.4; only the VAD model
and runtime are loaded from `~/work/cassini-mac/build/Whistle`. All input is generated
zero PCM. The test uses the same asset availability guard as the other pipeline
tests; it was explicitly supplied and exercised in this local proof.

The earlier broad 415-XCTest/five-Swift-Testing logs precede this additional test;
production code is unchanged from that broad run. The speech-resume golden remains
an exact-head pipeline CI requirement, separate from this generated-only proof.
