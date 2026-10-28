# Library search

`CassiniSearch` builds an FTS5 index from read-only `LibraryScanner` snapshots.
Production stores `MeetingSearch-v1/transcripts.sqlite` under the app's sandbox
Caches directory. It never writes an index into Music/Cassini. Fixture app runs
use a separate private temporary cache. No audio decoding, devices or network
access are involved in indexing.

The actor updates changed transcript turns in a transaction and removes deleted
meetings. Speaker names, meeting dates and origin come from the current snapshot,
so renames and filter changes do not depend on stale cached metadata. A fresh app
launch rebuilds this derived index. A corrupt owned cache is rebuilt; symlinks and
hard links are rejected. Darwin realpath is needed because Foundation preserves
the /var alias, which SQLite's no-follow option rejects.

Typed text is bound as one literal FTS phrase, with embedded quotes escaped.
There are no Boolean, wildcard or prefix operators. The unicode61 tokenizer
handles case and accents. Highlight ranges refer to the original UTF16 text;
markup-looking text remains ordinary text. Multiple mentions in a turn become
separate places. Each seek uses the start time of the actual transcript item
containing the phrase, without inventing word times for sentence-level inputs.

D14 filters combine with AND. Named speakers are case-insensitive A–Z with
unnamed entries omitted; local calendar midnights define Today/7/30-day presets.
Own means origin own. Results sort by newest meeting and then transcript order.
Closing Search, opening/importing a meeting or closing its window resets filters.
The selected search result is the target of Export. Pending searches disable hit
actions until the corresponding result snapshot is ready.

Command-F opens Search from the Library or Meeting page. The normal Library has
a trailing native search field; Search uses the board's sidebar field. Escape,
the native clear control and Command-[ return to the Library. The context pane
opens or plays from the selected hit using the existing Meeting player.

Run `swift test --filter SearchTests` for the independently checked shared4/3
fixture, literal phrases/Unicode, repeated occurrences, filters, DST boundaries,
updates/removals, cache recovery and Library-byte preservation. `test-search-app.py`
checks the real sandbox app's model/filter/navigation path without playback.
LibraryBoards adds real UI/menu/keyboard coverage and search.png to ux-boards.
`render-local-ux.py` is explicitly an own-view fallback, not XCTest evidence.
