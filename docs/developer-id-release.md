# Developer ID download build (D34)

`scripts/release.py` builds a universal Release app, signs it during the build,
verifies every executable, notarizes/staples the app, creates an APFS/LZFSE DMG
with an Applications link, signs/notarizes/staples the DMG, and writes its signed
Sparkle appcast and SHA256SUMS. It does not publish, launch, install or update apps;
`scripts/publish-release.py` publishes a finished release (below).
The default feed is `https://cassini.talk/download/mac/appcast.xml` (D34.1).
Updates stay disabled in normal/CI builds; the signed release build enables them.
Sparkle's standard UI owns update permissions/preferences.
The sandboxed app uses Sparkle’s downloader/installer XPC services; no new network
client entitlement is given to the main app. No system profile is sent.

All credentials remain in `~/.config/cassini/secrets` (directory0700/files0600).
Developer ID uses `cassini-signing.keychain-db`, never the login keychain.
`scripts/setup-signing-keychain.py` imports the returned `developerID_application.cer`
and matching `developer-id-application.key.pem`, grants codesign/productbuild
access, adds only that keychain to the existing search list and proves signing
without running its generated Mach-O. Its random password is retained in
`cassini-signing-keychain.password`. Release unlocks it and sets a6-hour timeout.
Do not copy credentials into environment variables, source control or logs. Every tool call
in `release.py` and `setup-signing-keychain.py` goes through `scripts/safe_process.py`: a
failing, hung or interrupted (Ctrl-C) command reports only its tool and subcommand, never
its arguments or output, and both entry points end any exception in one sanitized line.

`notary.json` is an owned0600 JSON file with `key` (absolute path to the existing
ASC `.p8` file), `keyId` and `issuer`. Obtain these through the private local
configuration/iOS handoff, not chat. Never paste the API key into this file.
The retained `sparkle-ed25519.key` is Sparkle’s base64-encoded32-byte Ed25519 seed;
only `Distribution/sparkle-public-key.txt` is public. The release verifies the
seed derives that public key before building. Do not replace it for routine builds.

For example (use approved version/build values):

```sh
python3 scripts/release.py --version 0.1.0 --build 2 \
  --base-url https://cassini.talk/download/mac \
  --release-notes Distribution/release-notes/0.1.0.html \
  --output build/release-2
```

The output directory must not already exist. The build log and safe notary
submission IDs/status are retained there. Credentials and key-tool diagnostics
are suppressed. The release refuses generated `UITests/Fixtures/Library` data
in either the source tree or the final app, including leftovers from a prior
screenshot or incremental build. Use a clean release checkout/product.
No `--deep` signing occurs: nested Sparkle components are signed
inside-out before the app, while engine/worker signatures are made before their
`bundle-sha256.json` files. There is no post-build re-signing. The download/archive
signature is made after stapling the DMG. The appcast itself is also signed.

The base URL is configurable; the script derives the feed, versioned DMG,
latest copy and notes paths from it. Output includes the immutable
`Cassini-talk-<version>.dmg`, a byte-identical `Cassini-talk.dmg` copy, `appcast.xml`,
`SHA256SUMS`, `release.json`, and the ordered `publication.json` checklist.
Both DMGs are checked against the public Ed25519 key. Required
`--release-notes path/to/notes.html` copies that HTML to
`notes/<version>.html` and adds the appcast link. The staged application is named
`Cassini talk.app` before notarization; developer build paths keep `Cassini.app`.
No versioned artifact or existing staging directory is overwritten.

**Publishing (D34.1).** `scripts/publish-release.py` runs `publication.json` with rclone
into the Mac-owned prefix `download/mac/` of the cassini.talk bucket, and nothing else:
it only runs `rclone copyto` to keys under that prefix, never `sync`, delete or move, and
never touches the site's `index.html` or `404.html`. Credentials stay in
`~/.config/cassini-talk/r2.env` (see the coordination repo's CASSINI-TALK-PUBLISHING.md);
the script sources them inside `sh -c` and never prints them.

A dry run is the default and changes nothing:

```sh
python3 scripts/publish-release.py build/release-2
```

An upload is public at once. Run it only after notarization and clean-VM QA have passed
on this exact DMG and the coordinator has confirmed the release:

```sh
python3 scripts/publish-release.py build/release-2 --publish 0.1.0 --clean-vm-qa-passed
```

It checks every file against `SHA256SUMS` and the release's base URL. Before any upload,
in a dry run too, it reads the appcast deployed in the bucket (not the CDN copy) and refuses
a lower version or a build that is not higher than the deployed one, because Sparkle offers
only a higher build and an older upload would roll back the latest copy and the feed. The
one exception is a retry whose appcast is byte-identical to the deployed one. An exclusive
lock on `~/.cassini-release.lock` is held from that read through the last upload (a second
publisher on this machine fails at once), and the deployed appcast is read again just
before the feed upload, which aborts if it changed. Then:

1. Uploads `Cassini-talk-<version>.dmg` with `--immutable`: an existing versioned file is
   never replaced.
2. Verifies the actual HTTPS download (`verify-release-download.py`: complete length,
   SHA-256 and Ed25519 with the public app key) before changing the latest copy or feed.
3. Uploads `Cassini-talk.dmg`, a copy of that same verified DMG.
4. Uploads `notes/<version>.html` (immutable) before the feed references it.
5. Uploads `appcast.xml` **last**.

It stops at the first failed step. The CDN can serve the previous latest copy or appcast
for up to 5 minutes.

Run `python3 scripts/fetch-sparkle.py` and `python3 scripts/test-release.py` for
pure-file/XML/privacy and real upstream sign/verify/tamper checks. The tools and
SPM framework are pinned to Sparkle2.10.1 (source revision in the checked-in
Xcode Package.resolved; distribution SHA256 in the fetch script). Every hosted
architecture, model golden, browser and UX gate remains in place.

A signed artifact is not proof of a clean install. Before publishing, Mac QA must
check the actual quarantined DMG in a disposable VM: `spctl -a -vvv`,
`xcrun stapler validate`, first launch (standard download prompt only), native
messaging from `/Applications`, and an N→N+1 Sparkle update including active
recording/quit safety. D39 bundled-companion setup replaces the old store-listing
release hold. The site pages outside `download/mac/` and the user README are coordinator-owned.

Versioned release-note sources are in `Distribution/release-notes/`. Pass the file matching the version being built. They describe that release’s changes and include local styling for both Sparkle and a browser; the exact final HTML is signed separately before the appcast is signed.
