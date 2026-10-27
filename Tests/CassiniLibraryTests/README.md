W1-M2 / Wave 1.5: HARMONY §§3/4/6, DECISIONS-UX D2/D3/D6/D7, LIBRARY-RULES R1–R10.

The 69 format and 17 state cases are coordinator-owned, copied verbatim. SHA256
assertions pin format v3 and states v2. Run:

    TZ=UTC LANG=C swift test --filter Library

Temporary-root regressions cover visible status/error precedence, exact embedded
references, recovered display end, completed captures with a missing WAV, quotes,
speaking order, import commit markers, file safety and read-only ownership.
Cache tests verify that unchanged Opus is parsed/verified only once, inode changes
invalidate it, and incremental scans replace only the affected meeting. Watcher
tests check metadata filtering, ignored WAV appends, 250 ms debounce / 2 s maximum,
and real FSEvents in a temporary root. UI clients use scanInBackground.

D6.1 is adopted with the coordinator's updated schema: queued/running ETA may be
null; a non-integer or negative ETA invalidates the whole metadata file. There is
no reader exception. Fractional offset ends use exact decimal digits and integer
sample remainders. Both prefixes retain the same UUID but distinct libraryKey.

S-3a: all 13 expectations were independently reviewed against rules/input trees
before this production-scanner adapter ran (coordination REPLIES-MAC.md). It
compares the complete JSON shape, preserves null fields and array ordering, and
pins every vendored file with SHA256. Main + each R1–R9 group are required; empty,
first-record and received-only are also run. CI artifacts retain actual/expected
JSON per case. The shared Onboarding descriptor issue was fixed by its owner in 72862aa;
all expected JSON remains unchanged. Every case runs against that pinned snapshot.
No app UI, metadata writer/importer, processing engine or capture protocol changes.
No test uses the user's Library, browser or audio devices.
