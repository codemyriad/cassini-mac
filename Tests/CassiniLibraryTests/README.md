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

D6 R3's ETA rule is an explicit exception to the older schema's required integer
ETA for queued/running jobs: unavailable/invalid estimates normalize to nil in
memory; all other schema validation is all-or-nothing. No files are rewritten.

S-3a is not claimed yet: waiting for the coordinator's fixture ping, then expected
JSON will be independently reviewed from input trees and R1–R9 before running it.
No app UI, metadata writer/importer, processing engine or capture protocol changes.
No test uses the user's Library, browser or audio devices.
