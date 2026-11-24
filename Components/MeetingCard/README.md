# W2.3 meeting card surface

`MeetingCard(isSelected:content:)` is a generic visual container for caller-owned row content. It implements the rest and neutral selected lift from Row-Mac / L-19. All colours come from `CassiniTokens`, including sRGB mixtures; no palette is copied here. Rest uses the `card-rest` role in both modes (light `#FAFAFB`, dark `#171A20`). Selected light uses `surface`; selected dark mixes `ink` 7% into `raised`. Selected borders mix `ink` 55% / 50% into `surface` respectively.

Named metrics follow the canvas: radius 7, interior padding 8 vertical / 10 horizontal, border 1, selected inset 0.5, inter-card gap 6. The selected outline draws a combined 1.5 pt inner stroke. Light selection has token `ink` at 12% opacity, y 2 and native shadow radius 4; dark and resting cards have no shadow. Padding is inside the 1 pt border, so the content origin is 11 pt horizontally and 9 pt vertically from the outer edge.

This component is wired into the main `Cassini` app target via `project.yml`. Callers own localized text, secondary ink, badge placement, truncation, list selection, keyboard navigation, and accessibility structure.
