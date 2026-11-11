# D95 meeting time

Contract: cassini-ux D95 at `106b3a0`; cassini-format pinned to
`32f37a6200c88bdd4d23c1f44497f1761f3401da`. The format's independent
conformance vectors 027–029 check recorded UTC precedence, creation-only DATE
rejection, and a meaningful legacy DATE offset. Tests also open, import and
rebuild those actual files through the production Library scanner.

The old reader failed the new reader/import/rebuild slice in 14 assertions.
Export tests exercise real PCM capture, packing nine minutes later, importing,
exporting and importing again; the displayed start stays at recording time.
They check UTC mirrors, identical DATE, unchanged meeting ID/audio digest,
site offset captured at recording start, missing site-zone omission, local
labels without conversion, and an unknown start with only a creation stamp.
Parameterized received/direct-open tests cover malformed optional local and
UTC fields while checking that source bytes and audio remain unchanged.
The malformed UTC cases failed 14 assertions before the final producer fix.

The frozen S-3a shared input files and original expected-file hashes stay intact.
`MeetingTimeExpectations.json` explicitly lists the six creation-only received
rows in four cases whose old displayed dates conflict with D95. The adapter
changes only their start/group fields; creation remains a sorting fallback,
so row order and every non-time expectation remain checked. These deltas were
independently checked with the pinned pure format reader before running the
production scanner.

Run `replay.py` under `~/bin/heavy-run` with Xcode 16.4 selected, SDKROOT set,
`CASSINI_OPUS_ASSETS` pointing at verified test Opus assets, and
`D95_EVIDENCE_DIR` pointing outside the checkout. It archives the current
commit into private scratch and runs the affected headless partition, both
conformance profiles, five separate production mutations, then restoration.
Each mutation must compile and fail an executed behavioral assertion.
The existing security-scoped bookmark case requires the login-session CI job;
this headless partition uses the same exclusion as CI. Integrated app builds
and that bookmark proof remain required in exact-head CI.

Full local logs and asset provenance are retained in
`~/coordination/evidence/big-mac-d95/` on the coordinator Mac. No real user data,
user-file migration, signing keys or device permission changes are involved.

Final local result after merging main `3faf774`: 416 affected headless tests and
56 CI contracts pass. Full conformance: 29 pass; metadata: 27 pass and two
expected profile skips. Five production mutations fail behavioral assertions;
all 26 focused tests pass after restoration. See `results.json` for source
hashes and representative failures. App source parsing passes; integrated app
compilation, UI checks and login-session tests are delegated to draft CI.

## Coordinator review follow-up

The GNOME review classes exposed two further Mac gaps. Unreadable Cassini
manifests and unknown major versions now produce no meeting time, including
through direct opening, import, catalogue rebuild and Markdown. Search uses
the calendar day's actual end, and the start of each earlier calendar day,
instead of adding 24 calendar hours to a possibly 01:00 boundary. Sao Paulo
and Havana midnight-DST cases assert exact inclusive/exclusive day and week
bounds. Together these tests failed 14 assertions before the fixes.

The own-capture round-trip test now also puts an older export with no UTC and
a conflicting local label beside the capture. The saved capture's trustworthy
UTC start still displays and is written on re-export with matching mirrors,
ID and audio hash. Stale/unverified export fixtures now carry a *valid* local
label, ensuring trust checks rather than shape validation discard it.

Date/clock pairs are checked against calendar components for `Etc/GMT-14`,
`GMT+0530`, `EST5EDT`, `America/St_Johns` and the current zone. The search/time
suite is also run in separate processes under `TZ=EST5EDT` and
`TZ=<+0545>-5:45`; no test changes the process timezone while others run.

`check-reference-when.py REFERENCE INSPECTOR --extra-cases DIRECTORY` compares
the Mac inspector to `cassini-read-pure.py` at the asserted format pin. All 29
vectors and both generated unreadable-manifest cases match its `when` result.
Generate the extra cases by running `unreadableCassiniDoesNotBorrowDATE` with
`CASSINI_D95_REVIEW_CASES` pointing outside the checkout. Two additional
production mutations remove the manifest trust guard and reintroduce the
midnight day-end bug; they must fail behavioral assertions.

## Exact-head CI Settings footer follow-up

CI run `42999320756` passed builds, conformance, package tests and board renders,
but its final Settings proof failed with `scanning: missing footer disappear
signal`. The updater had resumed; the standalone NSHostingView did not deliver
SwiftUI's `onDisappear` callback. After a normal merge of main `9fb263c`,
the DEBUG-only observer now follows native mount/removal of the actual footer
subtree via NSViewRepresentable. Release UI and updater behavior are unchanged.
No timeout was increased and the disappearance assertion remains required.

`footer-mount-probe.py` compiles the exact footer source and verifies 40 real
mount/removal cycles. With `D95_SPARKLE_FRAMEWORKS` set to the directory
containing the reviewed Sparkle 2.10.1 framework (including its SDK headers),
it also compiles the actual ApplicationUpdates and UpdateDeferralSelfTest
sources. Only unrelated live-work globals and catalog/theme adapters are
stubbed; the actual updater's fixture supplies each protected activity. The
real Sparkle ready window and mounted footer pass for recording, saving,
scanning, transcription and the Quit path. Both probes pass; 56 current CI
contracts pass. Run under heavy-run/Xcode 16.4, with
`D95_FOOTER_EVIDENCE_DIR` outside the checkout. Full local logs are in
`~/coordination/evidence/big-mac-d95/footer/`. Integrated Settings CI is still
required on the new head.

The next cached build exposed old compiled test clients referencing the original
four-argument RecordingSession initializer. That public initializer is retained
as a forwarding convenience overload; the explicit-zone initializer handles the
new capture-site recording. Both compiled symbols are verified in the rebuilt
object, and all 26 D95-focused tests pass after this compatibility change. This
preserves the existing public API while allowing explicit site-zone tests.

## Native hiding and detachment

Run `43009832544` was interrupted on two rented runners (GitHub annotations:
runner lost communication), and its hosted Settings job independently exposed
`recording: missing footer disappear signal`. No retry was started. NSView
representables may hide/detach before dismantling. The DEBUG observer now
reports those native transitions after a confirmed mount, once only; an
initial nil window cannot pre-seed successful removal. Release UI is unchanged.
The portable probe checks detachment, direct/ancestor hiding, initial-state
rejection and one-shot delivery, then 40 actual footer render/removal cycles
and the real Sparkle deferral self-test. All pass in a genuine Aqua session.
Three source mutations disable detachment, hiding or the mounted guard; each
fails a native transition assertion immediately, without waiting for a timeout.
Full logs: `~/coordination/evidence/big-mac-d95/footer/native-*.log`.
