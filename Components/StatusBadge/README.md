# W2.1 status badge component

`MeetingStatusBadge(kind:label:isAnimating:)` implements the seven visual kinds in the Mac canvas Badge contract. Every colour comes directly from `CassiniTokens` (#270); the component carries no palette or legacy tint-string adapter.

The coordinator approved a component-only slice. This source is deliberately outside the app target: agy-mac will add it to the target and wire LibraryView later. Include this source alongside CassiniTokens; do not duplicate either source. The caller supplies its localized label, resolves model precedence and maps the model's `needsAttention` to visual `.attention`. The importing fixture does not introduce an app state. Current labels and model logic are unchanged.

Geometry is 18 pt high, 11.5 pt semibold monospaced digits, 8 pt horizontal padding and 4 pt gap. Glyph sizes are 6 pt recording dot, 10 pt busy spinner and 11 pt alert/incoming symbol. Received has a transparent fill and 1 pt token-line outline. Explicit foreground roles prevent a selected row from replacing the badge ink.

Busy glyphs rotate once per second, at most 30 updates per second. Reduce Motion freezes the glyph; callers can also pass `isAnimating: false` when inactive or offscreen. The label is the single accessibility element; decorative glyphs are hidden. The standalone snapshots freeze animation and do not establish app-level accessibility or live-animation behaviour.

Native before/after light/dark proof, source receipts, static-glyph symmetry and outline-token checks, and four production mutation checks are in [evidence/mac/status-badge](../../evidence/mac/status-badge/README.md). No LibraryView, catalog, model, project or shared token file is changed here.

L-46 follow-up: Importing, Saving and Transcribing fill with token `ink` at 10% over the host surface. Foreground ink stays opaque; Recording, warnings and Received retain their existing treatment. See [native before/after proof and mutation replay](../../evidence/mac/status-badge-neutral-wash/README.md).
