<!-- SPDX-License-Identifier: GPL-3.0-or-later -->
# Per-user Connect implementation

The separately sandboxed `CassiniBrowserSetup.xpc` registers the two bundled
native hosts in Chrome, Chromium, Edge and Brave. Its only write exceptions are
four home-relative `NativeMessagingHosts/` leaves. It has no network, inheritance,
Downloads, arbitrary home-directory or administrator entitlement. The app's own
profile is unchanged. Setup never edits browser preferences or installs an
extension; D22's Add action belongs to the subsequent UI integration.

The RPC accepts two file bookmarks, checked against the two executable locations
derived from the helper's own containing app. These transfer read access to those
exact bundled hosts: the helper sandbox cannot otherwise read its parent app's
sibling payload. A bookmark for any different executable is rejected. The caller
cannot choose a host name, extension ID, destination, executable path or command.
Production uses the account home, not the helper's sandbox-container home.

Only browser trees that already exist are considered. Directories are traversed
without following symlinks; manifest reads reject symlinks, FIFOs, hard links,
foreign ownership, writable-by-others and oversized files. Directory leases
prevent concurrent Connect operations from interleaving. New leaves are 0700,
manifest files 0600, and every manifest has the single pinned extension origin.
Each file publishes through fsync plus rename. If a later publication fails,
earlier files are restored (new ones removed). This is rollback after reported
failure, not a cross-directory atomic transaction or power-loss guarantee.
A killed helper can leave a subset installed; repeating Connect repairs it.

Both native hosts and the setup service are embedded in Debug and Release.
There is no automatic setup or visible Connect button in this backend step.
The existing legacy CLI installer is unchanged. App-side setup/discovery and the
companion dialog follow only once capture ownership is integrated.

`test-browser-connect.py` packages a private headless fixture under `build/`,
with signed metadata selecting its generated home and only its four generated
write leaves. Release ignores that metadata. The production RPC and installer
code run unchanged; wrong-host rejection, eight manifests, exact allowlist,
private modes, repeated setup and denied parent writes are asserted. Hosted
native ARM/Intel consumers use the actual built Debug service/hosts and exact
parent product profile from same-run artifacts. The older XPC scope/network
probe remains. No user browser profile, device, Library or app window is opened.
