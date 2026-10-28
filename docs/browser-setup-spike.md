<!-- SPDX-License-Identifier: GPL-3.0-or-later -->
# UX10 per-user browser setup spike

Connect needs to register both native hosts for Chrome, Chromium, Edge and Brave.
The sandboxed app cannot write their NativeMessagingHosts directories directly.
The existing command-line installer does not establish app-side access.

The fixture proves a narrow alternative to broadening the main app: a separately
sandboxed XPC service with four home-relative read/write exceptions, each ending
at a NativeMessagingHosts directory. It has no network-client or inheritance
entitlement. The client uses the exact current Cassini product profile. Both
remain sandboxed; this does not use an unsandboxed installer or an OS privacy
permission bypass.

Apple documents [independent XPC sandbox capabilities](https://developer.apple.com/documentation/security/discovering-and-diagnosing-app-sandbox-violations)
and [home-relative file exceptions](https://developer.apple.com/library/archive/documentation/Miscellaneous/Reference/EntitlementKeyReference/Chapters/AppSandboxTemporaryExceptionEntitlements.html).
Home-relative paths start with `/` and directory paths end with `/`.

`Spikes/BrowserSetup/` contains build-only client/service executables. They are
not embedded in Cassini.app and expose no product setup action. The harness
creates a generated fake home under this checkout's build directory, packages
and signs a private app/XPC pair, and grants only those four generated leaves to
the helper. It never overrides HOME or registers in the account's browser
profiles. The signed fixture metadata binds the helper to that generated root.

The proof requires all of these outcomes:

- The client cannot write even a generated host manifest with the product profile.
- The helper writes eight manifests (two hosts/four browsers), with mode 0600,
  the fixed extension allowlist and the expected executable path.
- The helper cannot write an adjacent file outside its four permitted leaves.
- A real loopback connection is denied to the helper; the harness's positive
  control can connect. File positive controls prove the fixture owner can write.
- Code signatures, exact entitlement dictionaries and native architecture match.

Run locally only with the explicit private-workflow opt-in:

```sh
CASSINI_LOCAL_WORKFLOW_TESTS=1 python3 scripts/test-browser-setup-spike.py \
  --output /tmp/cassini-browser-setup-spike.json
```

Hosted ARM/Intel jobs use `--skip-build` and the matching D20 producer SwiftPM
products. Xcode 16.4, existing PR paths/full runs, all old tests and matrices stay.
The spike adds no second app build or compiler cache on a consumer.

This proves sandbox/XPC/file-scope mechanics on generated paths. It does not
prove actual browser launch, extension connection, installed-profile/TCC access,
app-group/socket bridging, crash-safe installer rollback or production path
validation. Those belong to the UX10 implementation. In particular, the fixture's
fake-home RPC is not a production installer interface: production must choose
the account home, fixed browser paths and its own bundled host executables.
