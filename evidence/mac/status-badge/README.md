# Standalone Mac badge proof

These four PNGs render native SwiftUI views offscreen at 2x. They are component boards, not application screenshots. Before uses the unchanged `LibraryTheme` and `badgePill` extracted from main at `f22a163906d2aaedfba60e2974de8986c56f6ec0`; after compiles the actual new component. Both use identical caller labels and a common token-ground board. Importing is a visual fixture only. Label/catalog changes and LibraryView adoption are outside this approved slice.

| Scheme | Before | After |
| --- | --- | --- |
| Light | [before](before-light.png) | [after](after-light.png) |
| Dark | [before](before-dark.png) | [after](after-dark.png) |

Reproduce on a Mac with Xcode 16.4 selected, under the shared heavy-run gate:

```sh
git fetch origin refs/pull/270/head
~/bin/heavy-run python3 scripts/render-status-badges.py \
  --tokens-ref c2f77c119671fb7c643f5ee024f245f23269e122 \
  --baseline-ref f22a163906d2aaedfba60e2974de8986c56f6ec0 \
  --output /tmp/cassini-status-badge-proof
```

The token source is read verbatim from #270 into the external output directory, never vendored or edited. Once #270 is merged, a main commit containing that source can be used instead. The receipt pins both input commits and source hashes, the component, renderer and proof source hashes, architecture, and all 14 successful badge/scheme checks. Native Apple Silicon and Intel targets are supported; these receipts were produced on Apple Silicon.

Checks cover token role/glyph mapping, 18 pt rendered height, actual tint pixels, transparent Received interior plus visible outline, actual glyph ink, and identical pixels under ordinary and selected-parent foregrounds. This last check establishes foreground independence, not integration in a selected Library row. Live animation and Reduce Motion are not exercised by static rendering. The renderer does not launch Cassini or change system appearance or audio devices.

`mutations.json` records two actual component regressions: removing the Received outline and letting the label inherit its parent's foreground. Each exits 1 with the named native assertion, rather than a timeout or compiler failure. Apply each committed patch in a disposable checkout, run the command above, verify the named assertion, then reverse the patch before the next case. The restored source passes all 14 cases. Source hashes in the receipt let a reviewer verify exactly what was rendered.
