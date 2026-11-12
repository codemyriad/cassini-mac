# W2.3 meeting card surface

`MeetingCard(isSelected:content:)` is a generic visual container for caller-owned row content. It implements the decided rest and neutral selected lift from Row-Mac / L-19. All colours come from CassiniTokens (#270), including sRGB mixtures; no palette is copied here. Light rest uses the approved card-rest role, dark rest uses its surface-equivalent pair. Selected light uses surface; selected dark mixes ink6% into surface. Selected borders mix ink55%/50% into surface respectively.

Named metrics follow the canvas: radius7, interior padding8 vertical/10 horizontal, border1, selected inset0.5, inter-card gap6. The selected outline draws a combined1.5pt inner stroke. Light selection has token ink at12% opacity, y2 and native shadow radius4 for the canvas blur8; dark and resting cards have no shadow. Padding is inside the1pt border, as in the CSS border-box model. The content origin is therefore11pt horizontally and9pt vertically from the outer edge.

This source is outside the app target under the coordinator's standing component-only authorization. agy-mac will include it alongside CassiniTokens when wiring LibraryView. Keep the native List selection, keyboard navigation, multi-selection and accessibility structure in that host; this component adds the selected trait but no gesture, focus or selection owner. There is no custom hover/press/focus policy. Pass rows in a stack with `Metrics.interCardGap` or apply the equivalent List spacing.

The wrapper defaults foreground to token ink. Callers own localized text, secondary ink, badge placement and truncation, and must remove legacy selected-white overrides. No row-anatomy, catalog, model or badge change is made here; no source from unmerged273 is needed. The proof keeps today's title/time/meta/quote order. App interaction and accessibility-tree integration remain untested until wiring.

Native before/after boards and pixel/mutation checks are in [the proof directory](../../evidence/mac/meeting-card/README.md). No user-facing release fragment is added for an unused component.
