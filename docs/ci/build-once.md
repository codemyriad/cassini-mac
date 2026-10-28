# Hosted CI products (D20)

`CI` is the sole PR/main/nightly orchestrator. It builds native SwiftPM executables
and test bundles once on ARM and Intel with Xcode 16.4. The ARM producer also
cross-compiles both app architectures, including the UI runner, in Debug and
Release. Universal Opus/Whistle/ONNX/Silero assets are staged once into those apps.
The Intel export and speech jobs still execute on real hosted Intel runners.

The six UX workflows keep their original matrices, assertions, fixtures, golden
comparisons and artifact names. They consume same-run products through
`workflow_call`; each also has `workflow_dispatch`, which first invokes the shared
producer. The central manual dispatch, push to main and nightly run all six areas.
The historical `ux/1a-library-model` push is retained and now runs the full suite.

`.github/ci/paths.json` preserves every original PR path pattern. The Ubuntu
changes job applies those patterns to a merge-base diff (including deletions and
renames). Changes to package sources/tests, shared engines or CI run every UX
area. Unknown bases and failed detection run every area; missing outputs also
select every area. The original unfiltered core CI still runs for every PR.
There is no automatic cancellation or concurrency group. Cancel superseded runs
manually, preserving the last candidate and all main/nightly runs.

Artifacts contain tar archives, so executable modes and relative framework links
survive transport. Before extraction, consumers require an exact checkout SHA,
Xcode version, native architecture (SwiftPM), pin hashes and archive SHA256.
They reject path traversal and external links. Products expire after three days;
re-run the complete workflow if they have expired. Caches accelerate the producer
but never replace the build. Fetch caches contain pinned source archives, not
trusted compiled Opus objects. Every pinned fetch validates its SHA. SwiftPM
caches include the architecture, compiler, manifest, sources, resources and pins.

The fresh hosted Whistle bundle job downloads only the complete Debug app/UI
product, with no raw assets or dependency/compiler cache. It re-signs the outer
app with the product entitlements (removing UI-test-only exceptions), verifies all
sealed engines and runs the actual sandbox-inheriting worker and export probe.
Screenshot jobs use `test-without-building` with the original UI flags and exact
PNG checks. These jobs do not generate a project or compile an app.

Release tags must have a successful push-to-main CI run on the identical commit.
The release workflow retains its version-stamped release build and publication.
This change does not create a tag or publish a release.

## Measuring

Run `python3 scripts/ci-metrics.py --sha COMMIT --output evidence.json` for a PR
push, or `--run RUN_ID` for a full dispatch. The file includes raw run/job records.
The report counts runner-assigned jobs, execution minutes, per-job rounded-up
macOS minutes, total wall time and median macOS queue wait. Billed minutes are an
estimate: the legacy GitHub timing endpoint currently reports zero even for
executed jobs; this is not a zero-cost claim. Cancelled queued jobs have no
execution charge. Cancelled running jobs count their actual assigned duration.
Compare equal coverage; a full dispatch has more areas than a narrowly filtered
PR. Queue wait is affected by other branches and cannot be attributed solely to
this change.

Local validation: `actionlint`, `python3 scripts/test-ci-contract.py` and
`bash -n scripts/bundle-{opus,whistle}.sh`. Hosted validation and measurements are
reported on the PR against the exact commit.
