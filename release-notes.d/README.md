# User release-note fragments

A PR with a change someone using Cassini can notice adds one `<short-slug>.md`:

```
kind: new
---
One or two plain sentences about what you can do now.
```

Use `new`, `better` or `fixed`. English, sentence case, typographic apostrophes;
use the [shared glossary](https://github.com/codemyriad/cassini-ux/blob/main/strings/GLOSSARY.md)
(meeting, Library, Saved voices, Record/Stop). Name where to find the change and
anything you must do. No PR titles/numbers, decision IDs, code/file names, links,
benchmarks, build machinery or internal terminology. Changes to that machinery
alone need no fragment. Do not describe a bug introduced and fixed between
published builds as a new fix; fold it into the feature it belongs to.

Keep fragments in Git after publication. Their names and contents in the previous
nightly and latest stable source tags form the ledger; an unchanged fragment is
not shown twice.
An edited fragment is new. Nightly overflow is covered by “and smaller fixes” and
is consumed with the other fragments at that tag. Stable notes still use every
fragment since the previous stable tag, including those in intervening betas.

Within a kind, use a leading number in the slug to put important changes first.
The renderer prioritises New, then Better, then Fixed, and keeps complete
fragments within500 UTF-16 units. Each fragment is at most400 units. See
[the writing and release procedure](../docs/release-notes.md).
