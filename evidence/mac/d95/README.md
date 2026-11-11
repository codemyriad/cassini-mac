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

## Settings footer layout proof

Run `43019387841` passed every check except the final Settings proof, which
reported `transcription: missing footer disappear signal`. Earlier runs failed
the same callback for other activities. Native SwiftUI container teardown is
not reliable evidence of whether the footer occupies layout. No failed run was
retried unchanged or counted as green.

The proof now uses a window-owned NSHostingController around the production
footer and a GeometryReader preference that records actual height and the
current updater state. After the real updater's busy/resume events, it awaits
the corresponding rendered layout and asserts positive busy height and zero
idle height. Including state in the preference means a footer that stays
visible reports idle layout with positive height and fails an assertion;
model state alone cannot prove removal. No callback is synthesized, no subtree
is manually removed and no success sleep or longer deadline is used. The
custom DEBUG native visibility observer is removed; production footer behavior
is unchanged.

`footer-mount-probe.py` compiles the exact ApplicationUpdates, footer and
UpdateDeferralSelfTest sources against the real Sparkle framework. Unrelated
live-work globals and catalog/theme adapters are stubbed; each protected
activity is supplied through the production fixture. Forty complete runs with
an occluding window pass for recording/saving/scanning/transcription and Quit.
`replay-footer-mutations.py` changes only the production footer conditional to
always visible or always absent. Both fail the intended layout assertion
without timeout; restored forty cycles pass. Patches and compact outcomes are
alongside this file. Earlier native-transition results are historical and
superseded by this measured-layout proof.

Run both scripts under heavy-run/Xcode 16.4 in an idle genuine Aqua session.
Set `D95_FOOTER_EVIDENCE_DIR` outside the checkout and
`D95_SPARKLE_FRAMEWORKS` to the directory containing reviewed Sparkle 2.10.1
with its SDK headers. Optional `D95_UPDATER_CYCLES` controls repetitions.
The mutation runner's optional `D95_GUI_PREFIX_JSON` wraps the proof command
when the checkout belongs to a separate coordinator account. Sources restore
in finally; do not build concurrently while mutating. Full logs remain under
`~/coordination/evidence/big-mac-d95/footer/`. Exact-head CI remains required.

The original four-argument RecordingSession initializer remains a forwarding
convenience overload for compiled test clients. The explicit-zone initializer
handles capture-site recording. Both symbols and 26 focused cases passed.
