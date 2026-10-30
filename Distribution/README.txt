Cassini for Mac

Requires macOS 15 or later. No developer tools are needed.

1. Move Cassini.app to Applications and open it.
2. This build is ad-hoc signed and not notarized. If macOS blocks it, click Done,
   then open System Settings > Privacy & Security > Open Anyway for Cassini and
   confirm. Approve only a build you intentionally downloaded here.
3. To record browser meetings, open Cassini > Settings > Browser companion.
   Choose Add from Cassini and follow the three steps. Cassini supplies the
   companion; no store account is needed. Copy the Extensions address, open it
   in the chosen browser, enable Developer mode, then Load unpacked using the
   copied folder location. Return to Cassini and wait for Connected. Reload
   meeting tabs opened before setup.
4. Press Record in Cassini. Every active browser meeting records into its own
   Library entry. When no browser meeting is available, Cassini records the
   microphone and this computer's sound, subject to macOS permission.
5. Open a recording to change Me / The others / Both or stop that meeting.
   The global Stop control stops every recording. Auto-record is an option in
   Settings > Recording and starts off.

Recordings stay in your Library, initially Music/Cassini. Move it through
Settings > Library. You can play recordings, write down what was said and export
portable Cassini files from the app. Existing audio stays available when a
microphone permission or another meeting fails.

Cassini checks the browser connection in the background after launch and updates.
Settings > Browser companion shows its state and Try again if a check fails.
Installing the app does not start a recording.

Cassini for Mac is GPL-3.0-or-later; COPYING contains the licence. Source code and
build instructions: https://github.com/codemyriad/cassini-mac . Bundled third-party
components keep their own licences in the app. PROTOCOL_COMMIT.txt identifies the
shared browser protocol revision used by this build.
