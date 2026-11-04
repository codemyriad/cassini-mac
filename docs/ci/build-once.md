# Hosted CI products (D20)

`CI` is the sole PR/main/nightly orchestrator. It builds native SwiftPM executables
and test bundles once on ARM and Intel with Xcode 16.4. The ARM producer also
cross-compiles both app architectures in Debug, including the UI runner.
Universal Opus/Whistle/ONNX/Silero assets and the Parakeet runtime are staged once
and shared. D66 mac-P2-2: the universal Release app is built from those staged
assets in a job of its own (`ci-build-release.yml`), which also packages
`Cassini-<sha>`; only that packaging and the Parakeet checks wait for it.
The Intel export and speech jobs still execute on real hosted Intel runners.

The UX workflows keep their original assertions, fixtures, golden comparisons
and artifact names. D66 mac-P1-4 folded three single-purpose jobs into the kit
job (the Library model tests with their UTC/C environment, the native recording
sink, and packaging Cassini.app, with the same artifact names) and keeps one
board-size capture. D66 mac-P2-1 merged three more: kit also runs the arm64
portable-export checks (with the Opus assets, the export report folder and the
independent cassini-format readers); one Intel `Package tests` job runs the
export and model-downloader filters, each only when its area changed; and the
window screenshots job captures the default size first, then selects a larger
display mode and captures 1120x720 (formerly `ux-board-shot.yml`, artifact
`board-screenshots-<sha>`). The kit and Intel package-test jobs run only inside
`CI`. The remaining `ux-*.yml` workflows consume same-run products through
`workflow_call`; each also has `workflow_dispatch`, which first invokes the shared
producer. The central manual dispatch, push to main and nightly run every area.
The historical `ux/1a-library-model` push is retained and now runs the full suite.

`.github/ci/paths.json` preserves every original PR path pattern. The Ubuntu
changes job applies those patterns to a merge-base diff (including deletions and
renames). Changes to package sources/tests, shared engines or CI run every UX
area. Unknown bases and failed detection run every area; missing outputs also
select every area. The original unfiltered core CI still runs for every PR.
A newer push to a pull request cancels that PR's older run automatically (D66
mac-P1-1: one concurrency group per PR number, `cancel-in-progress` on
pull_request only). Every push, nightly and manual run has a group of its own (its run id), so
none is ever cancelled or replaced while pending, so each main commit keeps the push run the release gate needs
(D20). Don't cancel runs by hand, main runs above all.

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
