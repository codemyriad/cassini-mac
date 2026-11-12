# W2.2 native label/kind proof

The snapshot pins **merged W0.4 793209cb3425bece7143178458fddd94b691e12d**. Four2x native boards compare the existing app catalog at mainaa634170 against that merged catalog. Both use the same merged W2.1 renderer, so the screenshots isolate label/kind changes. They are standalone component boards, not application screenshots. Before has no Importing key and explicitly shows a fixture annotation in its place. Current under-minute and no-ETA labels remain unchanged. All four PNGs were inspected.

| Scheme | Before | After |
| --- | --- | --- |
| Light | [before](before-light.png) | [after](after-light.png) |
| Dark | [before](before-dark.png) | [after](after-dark.png) |

With Xcode16.4 selected, run under the shared heavy gate:

```sh
python3 scripts/check-badge-labels-pin.py
python3 scripts/test-badge-labels-pin.py
~/bin/heavy-run python3 scripts/render-badge-labels.py --output /tmp/cassini-badge-labels
~/bin/heavy-run python3 evidence/mac/badge-labels/replay.py --output /tmp/cassini-badge-label-mutations
```

The proof compiles the actual new presenter/view, merged W2.1 renderer/tokens, and unmodified CassiniLibrary localization/live-timer helper files. A fixture Bundle.module shim enables standalone compilation; no LibraryLocalization.shared resource is read. English and all five translations come from the pinned whole catalog. No app launch, GUI runner, system appearance change, audio device or signing is involved. Receipt source hashes identify everything compiled; output stays outside the checkout. Receipt architecture is Apple Silicon; producer also supports native Intel.

Checks:18 shared meeting vectors,1 independent import-entry vector,3 ETA format vectors,41 Library expected badge rows,70 localized cases (six UI languages, one/million plurals, independent Arabic regional digits for English/Italian), missing-translation rejection,18 actual native badges and2 nil-view pixel comparisons against a nonempty anchor. Library snapshot adapters provide liveMs from their display-duration field only inside the proof. Actual views are compared against independently selected expected visual kinds, so a wrong needsAttention mapping fails.

Nine committed production patches regress positive ETA, Importing kind, queued state, recording/error precedence, Interrupted label, missing-language rejection, regional locale, visual-kind mapping and nil-view behavior. Each exits1 with its named native assertion, not compiler failure/crash/timeout. Replay applies the committed patches and restores both production files in finally; the restored full proof passes. Pin drift tests separately reject modified catalog/state/format/Library expectations. Live app wiring and accessibility placement remain agy-mac's work.
