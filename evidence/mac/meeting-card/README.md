# Native W2.3 card proof

Four PNGs compare rest/selected states in light and dark using identical fixture text and current row anatomy. They are standalone component boards, not app-window screenshots. Before extracts the actual row, badge, LibraryTheme and selected-background expression from main72d3704b; fixture adapters supply a fixed09:00 time, title, meta and quote. List-like8/10pt insets are applied outside the extracted row. No real List or keyboard behavior is claimed. After compiles the actual new generic component. The common board uses the token sidebar ground.

| Scheme | Before | After |
| --- | --- | --- |
| Light | [before](before-light.png) | [after](after-light.png) |
| Dark | [before](before-dark.png) | [after](after-dark.png) |

On a Mac with Xcode16.4 selected:

```sh
git fetch origin refs/pull/270/head
~/bin/heavy-run python3 scripts/render-meeting-cards.py \
  --tokens-ref c2f77c119671fb7c643f5ee024f245f23269e122 \
  --baseline-ref 72d3704b --output /tmp/cassini-card-proof
~/bin/heavy-run python3 evidence/mac/meeting-card/replay.py \
  --output /tmp/cassini-card-mutations
```

Tokens are read verbatim from270 into the external output directory, never vendored. The receipt records full input commits, token/baseline/fixture/generated-legacy/component/proof/producer source hashes and architecture. Apple Silicon and Intel native targets are supported; this receipt is Apple Silicon only. No app launch, GUI session, system appearance change, audio device or signing is involved.

Four native state cases independently calculate expected token mixtures and sample actual fill/border/inset pixels; require selected light shadow and no dark/rest shadow; verify a transparent rounded corner; measure50pt content plus8/10 padding and1pt border; assert6pt inter-card spacing; and compare pixels under ordinary and on-accent parent foregrounds. Eight committed production patches regress selected fill, shadow, selected inset, inherited ink, border mixture, corner radius, horizontal padding and card gap. Each exits1 on its named native assertion (not compiler failure/timeout); the restored source passes all four cases. Replay applies the exact patches in a disposable checkout and restores source in finally.

An initial optional stack probe could not render with EmptyView content. A transparent, layout-bearing rectangle replaced that fixture; baseline, all eight mutations and restored checks then passed. The production component did not need a change for that fixture issue. Hover/press/focus, keyboard selection, multi-selection and real accessibility integration remain the future host's responsibility.
