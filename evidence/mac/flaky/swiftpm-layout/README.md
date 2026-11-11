# SwiftPM cached nested-layout mismatch

[#248's kit run](https://github.com/codemyriad/cassini-mac/actions/runs/43073656749/job/130717229770)
reported missing corpus tracks, then SIGBUS. Its producer restored a different
source fingerprint from a main-branch cache, rebuilt CassiniLibrary but did not
recompile CassiniTranscriptionTests. D95 changed a nested public struct's stored
layout. A fresh diagnostic build at the same source passes the full XCTest
partition. The remote OS refused its crash report because the report quota was
exhausted; that host was inspected read-only.

The three-target probe demonstrates the compiler/cache failure independently:
Stamp has a computed orderingKey, Carrier stores a Stamp and an eight-element
tracks array, and the client reads tracks.count. Change orderingKey to stored
and incrementally rebuild: Swift 6.1 rebuilds Stamp/Carrier, reuses the client,
and the client exits with SIGBUS. A complete rebuild returns TRACKS 8.

The workflow now caches compiled SwiftPM objects only for identical source,
architecture, Xcode and workspace inputs. Removing prefix restoration avoids
mixing layouts. A new cache namespace excludes already-saved incoherent
products. Exact-input cache hits and all pinned download caches remain enabled.
The controlled probe reads the actual workflow's cache key and fallback policy,
then runs the real compiler using the objects that policy would restore.

| Policy | Cross-source objects reused | Native result |
| --- | --- | --- |
| Original prefix fallback | yes | SIGBUS (-10) |
| Fixed exact-input cache | no | TRACKS 8, exit 0 |
| Committed fallback-restoration mutation | yes | SIGBUS (-10), probe assertion fails |
| Restored workflow | no | TRACKS 8, exit 0 |

Select Xcode 16.4 and its SDK, set CASSINI_ABI_EVIDENCE outside the checkout,
and run probe.py under ~/bin/heavy-run. The probe generates only a tiny temporary
package. To check the mutation, apply restore-prefix.patch and run the same
probe; restore the workflow afterward. No clock/CPU assertion, fixed sleep or
wall-time success path is involved. All 57 CI contracts pass. Logs remain under
~/coordination/evidence/mac-flaky/cache-* on the coordinator.

D87 #12 checks exact-source compiled artifact coherence; #17 uses actual native
exit and eight-track assertions, with a configuration mutation that reintroduces
the native fault; #18 based directly on main fc2ad76; #19 exact-head CI pending.
Other classes are unaffected by this cache-policy change.
