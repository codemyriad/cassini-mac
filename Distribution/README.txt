Cassini for Mac — local browser recording

Requires macOS 15+. No Swift compiler, Xcode, Python or Homebrew is needed for setup.

1. Keep this folder in a permanent location, or move Cassini.app into /Applications and
   keep BrowserExtension in another permanent location. Chrome loads that directory in place.
2. Open Cassini.app once. This development build is ad-hoc signed and not notarized.
   If macOS blocks it, click Done, then System Settings > Privacy & Security > Open Anyway
   for Cassini, and confirm. Approve only a build you intentionally downloaded here.
3. Open Chrome once. In chrome://extensions enable Developer mode, click Load unpacked,
   and select this folder's BrowserExtension directory. Copy its 32-letter extension ID.
4. Double-click Install Browser Host.command, paste that ID, and press Return.
   It uses the bundled executable and registers it in existing Chrome/Chromium/Edge/Brave
   user profile directories. It never changes browser preferences or installs another browser.
5. Reload the meeting tab. Open Cassini's extension and choose Record separate tracks, or
   Record the whole tab if individual tracks are unavailable. Stop and save finalizes the files.
6. Recordings are in ~/Music/Cassini. Cassini > File > New Recording > Open Recording Folder
   opens them for review. Native output/microphone recording separately needs macOS consent.

After moving Cassini.app or changing the extension ID, rerun the installer. The installer uses Cassini.app
beside it, or /Applications/Cassini.app after the app has been moved there. For a custom
app location, run its Contents/MacOS/cassini-browser-host --install-extension EXTENSION_ID.

Uninstall browser integration from Terminal:
  /path/to/Install\ Browser\ Host.command --uninstall
This removes Cassini's native-host registrations; it retains the app, extension and recordings.

Track labels are untrusted display names, not verified identities. Transcription and portable
Cassini Opus export are future work. See PROTOCOL_COMMIT.txt for the shared extension revision.
