# External recording files

File > Open… (Command-O), Finder events and the Library's received-file actions
use one app-wide router. Its scene-opening action remains available after the
Library closes, and launch-time URLs wait for that action to become available.
One standardized file URL identifies one legacy viewer. Play is a transient
request and is excluded from scene restoration; Read and Play reuse the viewer.

User-selected URLs acquire a security-scope lease before scene encoding. The
background read, session and player retain that same lease. Closing a viewer
cancels its tasks and shuts down playback, while a read already in progress keeps
access until it returns. A file-read error dismisses the loading viewer before
the existing system error presentation, so an empty spinner cannot remain.

The GitHub-hosted Library UI suite exercises Command-O and Finder events after
closing the Library, duplicate Finder/Read/Play routing and a missing-file read.
Legacy whole-window and sheet screenshot gates retain their original fixture
identifiers. Local verification builds the UI tests without launching the app.
