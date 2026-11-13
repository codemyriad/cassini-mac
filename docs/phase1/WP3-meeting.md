# WP3 Meeting view

This package follows L-22, L-24, L-43 and L-44 in the Phase 1 decisions log. `LibraryOpen-Mac*.dc.html` is the pane reference; it supersedes the older separate-speakers `Meeting-Mac` board. Verified portable summary attachments open in Summary first, with Summary/Transcript tabs only when an attachment exists. The existing Markdown renderer keeps headings, lists, task items and timestamp links; Find switches to Transcript, and Library search opens its matching transcript row.

WP3 includes main after Foundations #290 (`cf368749`) and Library/Search #293 (`51975621`). It retains the final stored-speaker-slot and off-main preparation fixes, plus main's release admission and native probe fixes. Foundations carries the canonical UX pin `5e0c34e0f1bb390298dabdf4eedc494e933fd329`, including the Find/empty-selection strings and final theme helpers. WP2's sidebar Search, row cards, import controls, transient imports and drop states are retained. Saved meeting panes keep those Library controls; recording pages keep their existing owner.

## Pane and ownership

LibraryView keeps the Library list beside the real meeting. Single selection and keyboard selection open it directly; multi-selection retains bulk export. Explicit list interaction can switch away from an external document, but a background Library refresh cannot replace one. Global Search uses WP2’s sidebar field; the duplicate toolbar field is removed. Closing global Search restores the selected meeting.

MeetingPaneHeader owns the heading, rename pencil, date/duration and inline speakers. Writable names open the existing speaker editor; read-only names remain plain text. Independent speaker Play, provenance, turn timing and talk shares remain accessible through the inline row and its context menu. No saved-voice backend or new persistence is introduced.

The heading scrolls away; its measured height drives the compact toolbar title/date. Export and the existing system-Trash action share a capsule; recording details and Undo merge remain in More. No Recently Deleted store is invented. Existing received-folder information remains until WP7.

The player floats in an explicit hit-testable layout with existing seek, skip, rate and listening controls. Its measured height supplies transcript bottom padding. In the narrower pane, listening excerpts reflow below their controls rather than disappearing.

The native scrubber uses its public trackFillColor with CassiniTheme.nsAccent, preserving native thumb, pointer, keyboard and VoiceOver behavior while ignoring the system accent (L-06). The actual native primitive proof requires that role.

## Find

The pinned native Find field stays reachable during next/previous navigation. Cmd-F focuses it while a meeting is open. A detached cancellable task searches the shared MeetingPresentation.prose projection; inline asides appear once in their visible host. Foundation's case/diacritic-insensitive literal search returns UTF-16 ranges for the exact TextKit string. No range recomputation or normalization changes the displayed transcript.

TextKit applies shared token highlight colours without replacing native selection or seek/listen attributes. Find searches contiguous spoken spans from the projection's seek anchors, excluding synthetic aside labels and delimiters while retaining exact UTF-16 offsets. Spoken names remain searchable. A query/revision guard rejects obsolete results. Empty queries skip paragraph construction. Find focus yields keyboard input, including spaces, rather than executing playback/transcript shortcuts. Finding and changing matches scrolls without seeking or starting playback.

Global Search supplies the exact prepared row ID for hit revelation, with position as fallback when no row context is available. The existing audio seek/autoplay policy is retained independently. Background selection opens the pane without activating the window, so it cannot steal focus from Settings. The retained list keeps its Shift-F10 menu when it has keyboard focus. Trash blocks automatic opening during its transaction and an empty selection clears an app-owned pane; another remaining meeting may open after deletion.

Recording editor cache pruning runs when a page is presented, not whenever SwiftUI evaluates an initializer. Repeated background page lookups cannot evict a separate active editor; the existing comfort probe explicitly checks that identity. Capture and title writers remain unchanged.

## Verification and screenshots

TranscriptFindTests exercise Unicode offsets, accented/decomposed words, phrases, repeated occurrences, missing/empty queries, next/previous wrapping, cancellation and the real shared inline-aside projection. The D70 listening and D84 interjection regressions protect existing transcript anatomy. All heavy commands run under ~/bin/heavy-run; Xcode 16.4 builds explicitly select macOS SDK 15.5.

Native UI tests exercise direct selection changes, read-only/writable speaker controls, local Find/cycling/clear/space input, global Search guards and actual scroll geometry. The app prepares the scrolled case from a sealed Library fixture inside its own sandbox, with additional bounded transcript turns; no forced compact-header state. Find also asserts the match count has enough visible width, rather than accepting an accessibility label on a squeezed-away view. Header and compact-title containers expose their children independently. Screenshot export requires meeting-open, meeting-find and meeting-scrolled in both light and dark, alongside existing meeting boards. The explicit dark-mode CI test list includes both new test cases; the light lane runs the whole LibraryBoards suite.

The meeting accessibility case requests an idle activity snapshot when checking
the Record action. Normal board cases retain the fixture's live recording state;
the accessibility case keeps its strict Record, Import, export and playback labels.
The header Record action uses the existing native button owner so its label
cannot inherit the adjacent SwiftUI Import label. Each action must appear once.

The existing ui-shots job supplies actual app before/after pr-shots and source/run provenance. The coordinator explicitly authorized big-mac to publish the final exact-head light/dark artifacts with scripts/pr-shots.py; no pruning. Readiness requires complete exact-head CI plus validated, published light/dark pr-shots. The D-1008 continuation uses Seat: local-codex and Participate: auto. WP4, WP5, WP6 and WP7 follow in the dispatched order; Phase 2 is excluded.
