# W2.2 status badge labels

`BadgeLabelPresenter` derives the localized badge label for all six desktop meeting states (`recording`, `saving`, `transcribing`, `interrupted`, `needsAttention`, `received`) plus `importing` from the shared `cassini-ux` catalog (`strings/strings.json`, `vectors/states/states-vectors.json`, and `format-vectors.json`), without formatting labels from English fragments.

`CatalogStatusBadge` pairs `BadgeLabelPresenter` with `MeetingStatusBadge` from `Components/StatusBadge`.

This component is wired into the main `Cassini` app target via `project.yml`. Its standalone contract snapshot under `Components/BadgeLabels/Contract/` is verified by `scripts/check-badge-labels-pin.py` and `scripts/test-badge-labels-pin.py` (`.github/workflows/badge-labels-pin.yml`).
