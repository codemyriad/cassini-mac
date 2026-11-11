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
conformance profiles, three separate production mutations, then restoration.
Each mutation must compile and fail an executed behavioral assertion.
The existing security-scoped bookmark case requires the login-session CI job;
this headless partition uses the same exclusion as CI. Integrated app builds
and that bookmark proof remain required in exact-head CI.

Full local logs and asset provenance are retained in
`~/coordination/evidence/big-mac-d95/` on the coordinator Mac. No real user data,
user-file migration, signing keys or device permission changes are involved.

Final local result after merging main `3faf774`: 413 affected headless tests and
56 CI contracts pass. Full conformance: 29 pass; metadata: 27 pass and two
expected profile skips. Three production mutations fail behavioral assertions;
all 23 focused tests pass after restoration. See `results.json` for source
hashes and representative failures. App source parsing passes; integrated app
compilation, UI checks and login-session tests are delegated to draft CI.
