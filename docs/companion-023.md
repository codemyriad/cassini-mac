# Browser companion 0.2.3 adoption

The app vendors reviewed protocol commit
`6e581d66cfe897f13b05445ae4f67392619e08ff` unchanged. Its 0.2.3 runtime preserves
rapid page transitions and collects all tabs' current discovery state after
asynchronous metadata lookups. The source snapshot, Git commit proof and
BrowserExtension copy are checked by `browser-protocol/verify.py --pinned`.

The Mac control reader clears only the departing tab's cached source count and
heard flag on navigating/closed status. Present status updates lifecycle state
without reviving those values; a new meetings snapshot supplies fresh source
evidence. This includes tab-scoped top-level status and inactive session entries.
Lifecycle timestamps use the existing injected monotonic registry clock. Command
results still respect the newer-status/revision guard before changing the cache.

The production registry and lifecycle policy run all four literal wire vectors,
asserting cached evidence, timer origins and actions, alongside the existing
15 normalized lifecycle cases. The hosted real app probe now sends navigating,
present and zero inventory in that order and requires system fallback in the
original live recording before original-transport restoration. Its report must
contain rapidReloadInvalidatesCachedSources; local app/device execution is not
needed for file/registry tests.

The filesystem upgrade test installs the real 0.2.2 runtime from bb13da92, then
uses the production bundler and installer for 0.2.3. It checks all 17 files
(15 runtime resources plus licence and pin), changed background/control bytes,
the new commit marker and unchanged inodes/dates after repeated preparation.
Fixture provenance and archive SHA256 are under
Tests/CassiniBrowserSetupTests/Fixtures/Companion022. No browser profile is used.

Git archive modes and permissive build umasks can otherwise leave group-writable
resources, which the native installer correctly refuses. The bundler now emits
0755 directories and 0644 data files and checks for group/other write bits. The
installer's existing no-follow, ownership, size and atomic replacement rules are
unchanged. The filesystem test deliberately bundles under umask 0.

Automatic preparation at app launch/activation replaces installed 0.2.2 files.
Running-worker self-update/version negotiation remains the separately assigned
D40 work. This adoption creates no Chrome Web Store package or upload.
