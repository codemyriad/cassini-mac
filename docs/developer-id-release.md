# Developer ID download build (D34)

`scripts/release.py` builds a universal Release app, signs it during the build,
verifies every executable, notarizes/staples the app, creates an APFS/LZFSE DMG
with an Applications link, signs/notarizes/staples the DMG, and writes its signed
Sparkle appcast and SHA256SUMS. It does not publish, launch, install or update apps.
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
Do not copy credentials into environment variables, source control or logs.

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
latest copy and optional notes paths from it. Output includes the immutable
`Cassini-talk-<version>.dmg`, a byte-identical `Cassini-talk.dmg` copy, `appcast.xml`,
`SHA256SUMS`, `release.json`, and the ordered `publication.json` checklist.
Both DMGs are checked against the public Ed25519 key. Optional
`--release-notes path/to/notes.html` copies that HTML to
`notes/<version>.html` and adds the appcast link; without it, no notes URL is
advertised. No versioned artifact or existing staging directory is overwritten.

**Nothing uploads.** Upload access and private `notary.json` are still pending.
Once notarization and clean-VM QA have passed and access is supplied, publish in
this order:

1. Upload `Cassini-talk-<version>.dmg` to `/download/mac/`; never overwrite it.
2. Verify the actual HTTPS download before changing the latest copy or feed:

   ```sh
   python3 scripts/verify-release-download.py build/release-2
   ```

   This makes a read-only HTTPS GET, checks the complete length and SHA-256,
   and verifies Ed25519 with the public app key. It rejects HTTP downgrades,
   truncated/extra/changed bytes and invalid signatures. It uses no signing
   secret or keychain, and launches no app.
3. Upload `Cassini-talk.dmg` as a copy of that same verified DMG.
4. If supplied, upload `notes/<version>.html` before the feed references it.
5. Upload `appcast.xml` **last**. Do not offer an update until its immutable
   download has passed step2. Stop on any failed step; the scripts have no uploader.

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
release hold. The public site upload and user README are coordinator-owned.
