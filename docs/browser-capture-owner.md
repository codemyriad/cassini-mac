<!-- SPDX-License-Identifier: GPL-3.0-or-later -->
# App-owned browser audio backend

Independent-session starts route `cassini-browser-host` to the protected audio
FIFO peer. Legacy starts retain their existing host/writer and 88 unchanged
conformance vectors. Management and PCM have separate connections: closing a
management peer does not stop audio. The approved shared snapshot is
`5cc4026c002cde0d7aecefed893c8b46f0e8e12b`; the extension remains version 0.2.0.
The coordinator owns the store package/version bump.

`BrowserAudioBroker` reserves opaque capture IDs and creates one
`OwnedBrowserCapture` per meeting. Registry locks protect pointers only; no file
I/O or native drain occurs under a global lock. A capture ID remains reserved
through browser loss while that folder continues recording. A malformed peer
receives a framed error and exits nonzero, without stopping other peers. App
Stop, browser Stop and Quit share one finalization operation. Native shutdown
has a bounded wait and an at-most-once completion; a failed drain marks the saved
folder incomplete. The app must flush browser Stop before shutting down peers.

The owner serializes writes/checkpoints on its own queue and publishes cached
snapshots without disk I/O in getters. Browser remote/media/tab tracks never
admit a page microphone. Me uses a distinct native sink. The future device owner
must stop admission and drain that sink before disabling a side, then create a
fresh sink generation when enabling it. Native sink finish ends its own tracks,
not the meeting. Do not run it on the owner's I/O queue.

Others off/on ends and restarts unique WAV spans with the same opaque
`sourceTrackId`. Incoming muted bytes are validated but never written. Buffered
pre-resume samples are trimmed. A source announced while off is checkpointed as
an ended empty span. Browser loss ends its spans and publishes `none/lost`;
a subsequent actual system PCM buffer publishes its system track and
`system/lost` event together in that same folder. Browser input never resumes
implicitly. Device frame-count drift cannot move control-event timestamps.

This PR supplies the backend and process/file tests. Cassini.app does not yet
launch this broker or own native inputs through it. Connect, host registration,
permission handling, the collection/activity adapter and UX10/11 remain separate
integration work. No production source chooser or fallback activation is claimed.

Tests use generated private roots and RAM PCM, never a microphone, audio tap,
user Library, browser profile or desktop. They launch the actual native-host
binary to check concurrent folders, independent Stop, management EOF, browser
loss, malformed frames/metadata and nonzero error exit. Native ARM and Intel
hosted consumers run the same suite from D20 build artifacts.
