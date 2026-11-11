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
so order within a calendar day and every non-time expectation remain checked.
Unknown dates collect into one trailing section rather than splitting known days. These deltas were
independently checked with the pinned pure format reader before running the
production scanner.

Run `replay.py` under `~/bin/heavy-run` with Xcode 16.4 selected, SDKROOT set,
`CASSINI_OPUS_ASSETS` pointing at verified test Opus assets, and
`D95_EVIDENCE_DIR` pointing outside the checkout. It archives the current
commit into private scratch and runs the affected headless partition, both
conformance profiles, 23 separate production mutations, then restoration.
Each mutation must compile and fail an executed behavioral assertion.
The existing security-scoped bookmark case requires the login-session CI job;
this headless partition uses the same exclusion as CI. Integrated app builds
and that bookmark proof remain required in exact-head CI.

Full local logs and asset provenance are retained in
`~/coordination/evidence/big-mac-d95/` on the coordinator Mac. No real user data,
user-file migration, signing keys or device permission changes are involved.

Earlier local result after merging main `3faf774`: 416 affected headless tests and
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
ID and audio hash. Non-OK Cassini exports preserve the complete original byte stream, including
local labels and untrusted claims; display trust checks remain separate from
export preservation.

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

The proof uses a window-owned NSHostingController and a stable measurement view
around the production footer. Its permanent one-point sibling keeps geometry
mounted even when the footer is empty; the reported footer height subtracts
that known point. Readiness is observed in the measurement view's `body`, then
paired with measured height in the geometry preference. Busy must occupy space;
idle must occupy zero height. An always-visible footer delivers idle layout
with positive height and fails an assertion; an always-absent footer fails the
busy-height assertion. Model state alone cannot prove removal. No subtree is
manually removed, no callback is synthesized and no success sleep or longer
deadline is used. The custom native observer is removed; production footer
behavior is unchanged.

The prior direct-background geometry proof in run `43030139951` failed with
`saving: missing idle footer layout signal`. The stable sibling prevents an
empty child from removing the measuring surface, and observing state in
`View.body` keeps invalidation independent of GeometryReader's deferred closure.
Fresh always-visible/always-absent mutations fail immediate height assertions;
forty restored occluded full updater cycles pass with this final host.

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

## Codex review corrections

Lowercase RFC3339 `t`/`z` now use one normalization path for recording UTC,
DATE/creation comparisons, import naming and rebuilt exports. Tests round-trip
all three lowercase combinations through direct opening, Library export and
re-import; equivalent creation stamps never become the meeting time.

Non-OK Cassini documents return before repair or replacement manifest creation.
Both direct-open and Library exports are byte-identical for stale audio,
unverified integrity, damaged metadata and unknown major versions. Tests retain
state, identity, metadata, time claims, original tags and transcripts (including
a 900-word stale transcript), even after a local title edit. Plain audio still
receives a new Cassini manifest; valid Cassini documents retain their existing
metadata-edit behavior.

Library sections collect by stable Gregorian calendar-day identity in the viewer
zone (civil labels retain their own day). Unknown dates collect once at the end;
section IDs are independent of translated headings. The unknown heading uses
`library.group.unknownDate` with the supplied language and locale. A mixed
known/unknown sequence checks membership, unique IDs and French translation.
The explicit D95 frozen-vector adapter collects only its six already-declared
creation-only rows into that trailing group; upstream bytes/hashes are untouched.

The initial new regression slice failed 68 assertions against the reviewed code.
The corrected affected partition passes 421 tests; 56 CI contracts pass.
`replay.py` also disables RFC3339 normalization, non-OK byte copying, day grouping
and unknown-date localization independently. Each production mutation must fail
an executed behavioral assertion, alongside the previous five D95 mutants.

After ordinary merge of current main `89c568b`, the 421-test affected partition
and 56 CI contracts pass again. The Debug arm64 app builds and links with
Xcode 16.4 and ad-hoc signing after generating the project as CI does. The
initial build using the stale checked-in generated project failed Quick Look
linkage; that invocation is retained in evidence and is not counted as a pass.
Generated project/workspace changes are excluded from the PR. Exact-head CI
(including the login-session and Intel checks) remains the readiness gate.

## Second review corrections

Calendar days, leap years, clock fields and UTC offsets are validated before an
instant can win over DATE. Equality uses integer UTC seconds and all fractional
digits, independent of Foundation Date rounding. Distinct submillisecond DATE
values survive read, export and re-import; equivalent values with different
precision or offsets remain creation-only. Reader values preserve their selected
text while exports canonicalize T/Z and retain fractional digits.

The same follow-up addresses the agy review: legacy DATE whitespace and space
separators match the pinned reader; civil labels are validated; Quick Look uses
the shared recording-time resolver; Library and Search use one total ordering
key, including fractions too small for Date. Unknown-date subtitles retain their
duration, Received provenance and Search position in all six catalog languages.

The regression slice failed 55 assertions against reviewed 60e3094. The affected
partition now passes 433 tests and the restored focused slice passes 43 tests.
All twenty independently applied production mutations compile and fail executed
behavioral assertions, without asynchronous expectation timeouts. Full
conformance passes all 29 vectors; metadata passes 27 with two expected skips.
The pinned reference reader agrees on all 29 normative vectors and 14 generated
actual read/export/re-import files, including impossible dates, submillisecond
DATE differences/equivalences and legacy space separators. Current hashes and
representative failures are recorded in results.json. Native build and CI
results are recorded separately; readiness requires complete exact-head CI.

The Debug arm64 app and Quick Look build and all 56 CI contracts pass with
Xcode 16.4. Generated project/workspace files are restored after the build.

## Agy review coverage

All six findings in `cassini-mac-248-agy.md` are addressed in the source at
44e0294. This follow-up adds independent export receipts and an explicit
malformed-local Library regression:

1. `PreviewText` calls `quickLookRecordingDate`; `SessionDate` is removed.
   `quickLookDateAssemblyUsesTheSharedRecordingTime` covers 027/028/029 and
   creation-only metadata, including a viewer zone on the previous day.
2. Direct-copy eligibility requires canonical recording and creation UTC;
   rebuilt manifests normalize both fields. The lowercase test checks exact
   strings, mirrors and re-import for all four casing forms, both creation
   forms, and direct/Library export. Both canonical production mutations fail
   executed assertions again after adding the independent receipts.
3. Legacy DATE accepts spaces/padding and compares normalized instants.
   Actual input/export files are compared against the pinned reader.
4. Civil labels require valid fields. `malformedCivilFilesShowUnknownAndSortByFallback`
   opens, imports and rebuilds four invalid labels; verifies unknown grouping,
   retained Received subtitles and ordering by the known fallback.
5. Library/Search compare one precision-preserving key. Tests cover every
   mixed-time permutation and fractions below Foundation Date precision.
6. Optional-time subtitle helpers render unconditionally. All six languages
   retain duration, provenance and Search hit position.

To reproduce the independent check, set `CASSINI_D95_R2_CASES` to an external
empty directory while running the focused export tests, then run:

```
python3 evidence/mac/d95/check-reference-when.py FORMAT_CHECKOUT CASSINI_INSPECT \
  --extra-cases GENERATED_CASES --validate-exports
```

The checker verifies the reference reader and timestamp schema are unchanged at
32f37a6, compares the actual `when` result, and validates generated timestamp
fields against that schema's patterns and calendar/clock validity. The current
receipt has 59 matching files (29 vectors, 30 generated) and 26 schema-checked
exports. Malformed input files are intentionally excluded from writer-schema
checks. Lowercase inputs follow the explicitly requested Mac read behavior;
canonical outputs are compared to the independent reader.

After this coverage addition, all 434 affected tests, 44 restored focused tests,
and 56 CI contracts pass. Production source is unchanged from 44e0294.

## DATE producer precision and invalid creation repair

Plain Opus DATE promotion preserves all supplied fractional digits in recordedAtUtc,
DATE, the UTC mirror, and creation UTC. Its existing minimum three-digit producer
form is preserved for timestamps that supply fewer digits. Repairing an invalid
creation field first retains a meaningful DATE as explicit recording UTC, so
changing creation cannot make that recording time disappear. Non-OK byte copying
still precedes these paths.

New actual-file read/export/re-import tests failed 20 assertions before the fix;
they now pass through direct and Library exports, retaining identity and audio.
All 436 affected tests and 46 restored focused tests pass. All 23 production
mutants fail executed behavioral assertions. The pinned pure reader matches 67
actual cases (29 normative, 38 generated), and 32 exported files pass the pinned
timestamp schema patterns/calendar checks. The plain input's DATE uses the app's
legacy import policy; the pure format reader supplies no `when` for non-Cassini
plain audio. That app policy is tested directly, and its resulting Cassini
exports are compared to the independent reference reader.

The original reviewed source passes a clean diagnostic CI job43083181757 and
557 local XCTest cases (36 expected device/model-profile skips). Its failed
warm-cache CI reused incompatible transitive clients: the separate #260 proof
reproduces Swift6.1 SIGBUS on a nested-layout change and fixes compiled cache
coherence. The separate #256 fixes the remaining Whistle EPIPE fixture. These
are readiness dependencies; neither failed job was accepted as green.

After ordinary merge of main eb60a0b, the generated-project native app/Quick Look
build, all 57 CI contracts, and 40 input-lifecycle XCTest cases pass. Generated
project/workspace files are restored; the owned export source is unchanged by
that merge. Complete exact-head CI remains required.
