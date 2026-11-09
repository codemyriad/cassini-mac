# Shared transcript rendering (D84)

The reference is `codemyriad/gocassini` at
`1111155cb0017b47c072a8662c54f28ad7c44223`. `TranscriptRendering` in CassiniKit
is a pure word-only port of its viewer pipeline:

1. `portable.ts`: `groupTranscriptSegmentsAsReadable`, then
   `mergeSmallReadableSegments`, over canonical word items in stored order.
2. `meetingExport.ts` / `overlap.ts`: `repairTurnFinalWordInflation`. Reference
   populations exclude punctuated candidates and nonpositive or punctuation-only
   words. The producer's `endsBoundedByAudio` attestation bypasses repair. Canonical
   input is retained; display ends alone change, never text, word identity or start.
3. Stable reading order, `buildTurnRuns` and continuity evidence at the 400 ms seam.
4. `nestTurnRuns` / `bestHostFor`: audible union <=2000 ms, side gaps <=500 ms,
   host split on both sides, at most one host block beginning inside the child,
   strict best-host scoring and one-level nesting.
5. `measureSimultaneity`: merged word intervals, >=150 ms, competing pairs only
   in `over`, largest collision first and each speaker named once.
6. `buildTranscriptRows`: only adjacent readable blocks split a paragraph; a chip
   prevents a break immediately after it. All of a turn's paragraphs stay together.
   `MeetingView.svelte` continuation hides a repeated name within 60000 ms while
   retaining the timestamp. `speakerList` supplies `A, B and C` formatting.

Blocks and row members retain input word indices. Words are atoms; the renderer
never splits whitespace-containing items, repairs punctuation or pairs quotes.
Producers/loaders enforce the single-word contract. This port takes canonical
words directly, so the viewer's display-token cleanup and source-reference
rejection paths have no separate representation to validate.

The six canonical fixtures and expected rows are copied unchanged into
`Tests/CassiniLibraryTests/Golden/interjections/`, including their reference
README and commit pins. `D84InterjectionFixtureTests` compares every row field,
member text, source word index and chip, and checks every atom appears exactly
once. Supplemental tests cover attested timing, stored quotes, overlap ordering,
crosstalk, continuation, seam thresholds and audible interjection length.

The core PR introduces this tested model without changing any surface. Follow-up
adoption replaces MeetingPresentation and the legacy Timeline adapters, then
wires Meeting, reader/QuickLook, Search/preview and Markdown to these same rows.
D63 speaker-gap boundaries must remain explicit at the adapter boundary.

## Surface adoption

The adoption branch replaces MeetingPresentation's private builder and
Timeline.buildTurns with adapters to TranscriptRendering. Meeting paragraphs,
inline chip selection/copy, Search indexing and context, Library and QuickLook
previews, both document windows and Markdown now share these rows. Library
preview/Markdown text uses MeetingPresentation.prose; QuickLook/legacy plain
text uses Timeline.text. Chips include their name and parentheses in copy text.
Names are hidden on continuation rows, clocks remain visible, and competing
labels appear once per turn in descending collision order.

App-owned speaker gaps remain explicit hard boundaries. The old D63 vector's
no-gap long-pause case still describes listening-span identity; D84 now gives
that case two readable rows. The other seven source-gap cases and gap mutants
retain their old assertions. D84 also supersedes D38.5 quote pairing: stored
quotes stay unchanged on all transcript surfaces, including search offsets.

The Cassini-file timing attestation reaches every adapter, Search fingerprints
and asynchronous preparation. Canonical word order is retained until readable
blocks have been built; sorting words first changes paragraph boundaries. D70
listening spans remain separate from reading paragraphs, and matching listening
words uses speaker/start/text so a display-only end repair cannot erase their
highlights. Search uses UTF16 word spans in the inline copy text, so a chip hit
seeks its own source word. Renaming a chip speaker invalidates the index copy.

The existing Mac export wrapper (localized headings, dates and clock format)
is retained; transcript paragraph order, text, inline chips and overlap decisions
come from the shared viewer model. Vector-driven adapter tests compare each
expected row and the resulting prose on Meeting, preview, QuickLook and export.

Stored R3 pull-quote selection and first-speaking roster order remain unchanged;
they are Library metadata derivation rules frozen by the shared S-3a vectors.
D84 changes the preview's transcript paragraphs, rather than replacing an
explicitly stored quote or the Library's quote-selection policy. All 22 Library
vectors continue to assert their complete expected fields without alterations.
