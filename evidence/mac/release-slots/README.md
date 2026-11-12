# Scheduled Mac release admission (RELEASE-SLOTS M-2/M-3/M-4)

The installer selects its running Python, or an explicit `--python`, validates
Python 3.9+/venv/zoneinfo, and preserves stable interpreter symlinks. Release
helpers use the selected interpreter rather than bare `python3`. Installer
fixtures cover 3.9/3.14 paths, including spaces; the full suite ran on actual
Python 3.9 and 3.12. No new runtime or package pin is installed.

Trusted scheduled CI participates in the newest exact-main gate. Pending/red
CI consumes neither the slot nor a manual request. A later timer pulse in the
same slot admits green main. An admitted failed build still reserves its number
and does not retry within that slot.

Failed products are deleted only after child exit and a schema-marked owned
failure. Keep three private archives of up to five 1MiB diagnostic tails each.
Active/unmarked/symlinked jobs, unowned archive collisions, and shared caches are
preserved. The release lock waits up to 60 minutes to share drmeyers with iOS.

Replay seven actual production regressions (31 baseline/restored policy tests):

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
