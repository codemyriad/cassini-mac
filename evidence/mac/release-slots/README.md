# Scheduled Mac release admission (RELEASE-SLOTS M-2/M-3/M-4)

The installer selects its running Python, or an explicit `--python`, validates
Python 3.9+/venv/zoneinfo, and preserves stable interpreter symlinks. Release
helpers use the selected interpreter rather than bare `python3`. Installer
fixtures cover 3.9/3.14 paths, including spaces; the full suite ran on actual
Python 3.9 and 3.12. No new runtime or package pin is installed.

Trusted scheduled CI participates in the newest exact-main gate. In-progress
CI leaves the slot and any manual request pending for up to 45 minutes across
minute pulses (with a 3-minute start grace for webhook run creation) and admits
the newest unpublished green ancestor if main fast-forwards into another
in-progress run, whereas completed red CI or an expired wait consumes the
slot/request as a skip. An admitted failed build still reserves its number
and does not retry within that slot.

Failed products are deleted only after child exit and a schema-marked owned
failure. Keep three private archives of up to five 1MiB diagnostic tails each.
Active/unmarked/symlinked jobs, unowned archive collisions, and shared caches are
preserved. The release lock waits up to 60 minutes to share drmeyers with iOS.

Replay 19 actual production regressions (42 baseline/restored policy tests):

```
MAC_SLOT_EVIDENCE=/absolute/path/outside/checkout python3 evidence/mac/release-slots/replay.py
```

The committed patches change interpreter selection/propagation, schedule
admission, early slot consumption, skipped pruning, active-job protection, and
lock wait. Each must fail an executed assertion. Fresh per-process bytecode
caches prevent same-second/same-size source mutations from surviving restoration.
The first non-isolated replay was discarded after exposing that cache collision.

All tests use temporary files, controlled CI responses and injected instants.
Installer/signing/publishing calls are mocked. No signing-host activation or
release dispatch is performed here. The coordinator owns installation after merge.

## Review round

All four major findings in `cassini-mac-272-agy.md` are addressed:

- The DMG heavy wrapper has a 4500s bound, covering the 3600s lock wait plus 600s task. The signed job has a 21600s bound, above the 19820s budget for two lock waits, two submissions/notary waits/stapling phases, compilation, image work and setup margin. Tests inspect the actual invocation timeouts.
- Pending CI is reported as waiting, once per `(slot, request, head)`. Green admission clears that pending key without consuming requests early. Pre-admission failure identity includes a newly discovered manual request; repeated identical failures remain deduplicated.
- Both test and stable xcodebuild environments carry `CASSINI_PYTHON`. All Python build phases respect it; the companion verifier uses its own `sys.executable`. Fixture executions exercise all three shell phases in cached and download modes and both project-authored Python phases with a broken bare python3 and a versioned selected path containing spaces. The installer includes an existing libexec/bin path.
- Default selection recovers stable opt/bin or system-launcher entrypoints for the exact running runtime, including macOS framework launchers. A simulated Cellar/framework binary behind an opt symlink tests the no-argument case; explicit interpreter symlinks remain preserved.

The project file was regenerated from project.yml. Tests do not run installers on the host, build signed products or contact signing services. Static runtime fixtures represent Python3.14; the actual policy suite runs on installed3.9/3.12. Review-round mutation replay uses fresh bytecode caches. An initial new environment check raised KeyError for its missing-key mutation; it was changed to assert on `.get`, and the complete replay was repeated successfully with all19 failures occurring on assertions.
