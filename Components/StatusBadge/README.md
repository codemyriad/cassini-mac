# W2.1 status badge component

`MeetingStatusBadge(kind:label:isAnimating:)` implements the seven visual kinds in the Mac canvas Badge contract. Every colour comes directly from `CassiniTokens`; the component carries no palette or legacy tint-string adapter.

This component is wired into the main `Cassini` app target via `project.yml`. The caller supplies its localized label, resolves model precedence, and maps the model's `needsAttention` to visual `.attention`.

Geometry is 22 pt high, 12 pt semibold monospaced digits, 8 pt horizontal padding, and 4 pt gap (`L-54`). Glyph sizes are 6 pt recording dot, 10 pt busy spinner, and 11 pt alert/incoming symbol. Neutral pills use `ink` at 10% (`L-46`, `L-54`); the `transcribing` spinner uses `accent` while `importing` and `saving` spinners use `ink-2` (`L-45`). `received` / `imported` uses a transparent fill and 1 pt token-line outline. Explicit foreground roles prevent a selected row from replacing the badge ink.

Busy glyphs rotate once per second, at most 30 updates per second. Reduce Motion freezes the glyph; callers can also pass `isAnimating: false` when inactive or offscreen. The label is the single accessibility element; decorative glyphs are hidden.
