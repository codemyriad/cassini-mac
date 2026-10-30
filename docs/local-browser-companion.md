# Browser companion supplied by the app

The app bundles the runtime files from its reviewed protocol pin, the public
Chrome identity key and GPL licence. `bundle-browser-companion.py --check DIR`
compares the shipped files byte for byte and rejects extra files or links.
The private store key is never an input. No Chrome Web Store package is made.

At launch and activation, the sandboxed BrowserSetup helper copies the bundled
folder to `~/Library/Application Support/Cassini/BrowserCompanion/extension`.
It accepts only a bookmark to its containing app's resource folder. The RPC
accepts no destination, executable or command. The main app gains no entitlement.
The helper's recursive grant covers only `BrowserCompanion`; its literal Cassini
ancestor grant does not cover siblings such as saved voices.

The copier checks the pinned extension ID and dotted numeric manifest version.
Equal or newer installed versions are untouched. A newer bundle is staged under
the same parent and exchanged atomically, with a nonblocking process lock,
bounded regular-file reads, no-follow traversal and rejection of hard links.
The browser reads updates on restart; D40's explicit update handshake is separate.

With `CASSINI_STORE_LISTING_PUBLIC=NO` (the default), Add from Cassini opens the
three-step guide. The user chooses an installed supported browser. Step 1 copies
its Extensions address and opens a blank tab, because Chromium ignores internal
URLs passed at launch. The user pastes the address, enables Developer mode, then
loads the stable folder using the copied path and the macOS folder chooser.
Done waits for the real native-messaging handshake. Browser profiles, preferences
and policies are never edited. A public-store build retains this as a secondary
link.

SDK tests use temporary files only. Sandbox, clipboard, browser and native UI
checks run on disposable GitHub-hosted Macs, never a user's desktop.
`test-local-companion.py` restores the existing app/UI-test products, launches a
fresh Chromium with external DNS disabled, and uses XCTest to follow the guide
without extension-loading flags or profile injection. It checks the clipboard,
native folder chooser, loaded ID and real handshake, then launches a private
N+1 app copy to check stable-folder replacement and equal-version no-rewrite.
Only the private copy's manifest/build versions change; the shared artifact's
signature is checked before and after. Screenshots, AX trees, the xcresult and
the result JSON stay in the browser-setup artifact, including on failures.
A loaded-extension test alone does not prove this flow.
