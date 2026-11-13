# Standalone W2.2 catalog badge

The WP7 Imported contract snapshot is pinned to merged cassini-ux main: **a08ee0aff82d58448b42d9799747088ae01ce1ea**. `Contract/UPSTREAM.json` records original source paths and SHA-256 for the whole catalog, statev3, formatv5, normative badge contract and all22 Library expectations. `scripts/check-badge-labels-pin.py` verifies all26 files; a Linux CI job also tests catalog/vector/expected-file drift rejection. Do not edit vendored bytes or pin an authoring branch.

`BadgeLabelPresenter(data:language:locale:)` prepares the pinned catalog using CassiniLibrary's actual `LibraryLocalization`. It rejects missing required keys or the selected language's missing translations instead of silently using English. Prepare it once outside View bodies; the host owns resource loading. UI language and regional number/timer locale remain independent.

Pass `.meeting(BadgeMeetingFields)` or `.importingEntry` to `presentation(for:)`. Meeting fields are already-validated projection data, **not a metadata parser**; persisted-file validation remains with the existing reader. Precedence, canWriteDown and live-timer rules remain the shared contract's. The timer uses actual `LibraryFormat.liveBadge`. No clock is started here: the caller supplies liveMs. Importing is an independent transient entry, not another persisted lifecycle or a priority against a recording. Nil means no badge. Model needsAttention maps to the renderer's visual attention kind.

`CatalogStatusBadge(presentation:isAnimating:)` renders through the W2.1 `MeetingStatusBadge` now merged in main. It owns no Library/Meeting state, keyboard selection, I/O or placement. The pinned catalog supplies every label, including compact positive ETA, Interrupted and Importing. Provisional zero-ETA/no-ETA text stays unchanged. No label is assembled from English fragments.

The app now compiles these sources and feeds validated meeting/transient inputs through
LibraryBadgeCatalog. WP7 advances the live catalog, component snapshot, model Golden
vectors and Library expectations together. Catalog bytes stay verbatim; documented
D81 onboarding fixture changes remain local to the existing test fixture copy.

See [proof and reproduction](../../evidence/mac/badge-labels/README.md). The app's localization/format helper sources and the merged renderer are compiled unmodified in that proof; a fixture-only Bundle.module shim is never called because catalog Data is passed explicitly. There is no duplicate palette, formatter or renderer.
