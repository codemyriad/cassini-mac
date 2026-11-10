# SwiftPM product workspace proof

Coordinator-assigned #208 blocker 1; branch `ci/rented-mac-routing-paths`,
base `17162d0ab810ddaeb65a17d3b7abfbb8b5c295f2` of `ci/rented-mac-routing`.
The base already contains the smallest fix: `identity('swiftpm')` records
`ROOT.resolve()`, and restore validates source, architecture, Xcode, pins, digest
and archive safety before rejecting foreign objects and building the consumer's
test products. This PR supplies real compiled integration coverage for that fix;
it does not replace it with an unproven symlink or rewrite generated bundles.
Setup-python belongs to the other #208 owner and is outside this change.

## Reproduce

Use Xcode 16.4 and acquire the host's shared `mkdir ~/.aws-heavy.lock` before
running either command; release only your own lock afterward. On this host the
wrapper `~/coordination/aws-mac-test.py` supplies both the lock and Xcode selection.

```
python3 scripts/test-ci-product-paths.py --evidence /tmp/product-path-evidence
python3 evidence/mac/rented-runner-paths/verify-cassini.py
```

The first command builds a tiny real SwiftPM package with a copied production
`ci-products.py`, actual Git identity, Xcode, pins, tar archive and resource bundle.
The producer and consumer have identical commits and different absolute paths.
It checks:

- Producer build, test and pack succeed.
- With the producer renamed out of reach, strict foreign unpack fails before
  extraction. The workspace-guard mutation instead restores foreign objects and
  the actual `--skip-build` test fails on resource or source resolution.
- Restoring the guard compiles at the consumer; its test checks both absolute
  resource/source paths and actual bytes through `Bundle.module` and `#filePath`.
- Moving the producer back and deleting its build tree allows the original
  archive to restore and pass without a build.

`verify-cassini.py` repeats the real producer build/pack and consumer rejection,
rebuild and skip-build steps with the complete unchanged Cassini package at the
exact base above. Three selected tests read model-fixture resources, wire vectors
and Whistle publication pins. The original producer stays unavailable throughout
consumption, and generated resource accessors must contain the consumer path.
The small PATH wrapper delegates to the real Swift compiler and only appends
`--jobs 4` to builds, respecting this shared Mac's compile budget. All fixture
bytes are synthetic or metadata; there is no network fetch, GUI or audio device.

## Results

Pending the shared host lock. No successful execution is claimed yet. Logs and
machine-readable results will be committed here after both proofs finish.

## Checked bug classes

Canonical source: cassini-ux main
`1e8a722060c3f014c67fa4eff13c454307cc31ea`, `review/BUG-CLASSES.md`.
Classes 3, 14, 16 and 17 are covered by workspace separation, strict verified
transport, no foreign extraction, real-byte assertions and failure-only command
bounds. Class 18: the coordinator explicitly requested this draft to target
the #208 branch; it is a fix-first dependency, not an independent main PR.
Class 19 remains pending; this PR must stay draft. Classes 1–2, 4–13 and 15 do
not apply to this build transport proof. No agy self-check is run.
