# Release notes for people using Cassini

User notes and the developer changelog have different readers. Follow the
[fragment rules](../release-notes.d/README.md) in every user-visible PR; internal
changes add no fragment. Use the [shared glossary](https://github.com/codemyriad/cassini-ux/blob/main/strings/GLOSSARY.md).

Test builds collect unpublished fragments at the admitted main SHA, group them
under New/Better/Fixed, and keep the user text under 500 UTF-16 units. Overflow
ends with “and smaller fixes”; without fragments the approved under-the-hood
message appears. PR titles, commits and source SHA appear only in the GitHub
release’s folded Developer changelog, below the user notes. The separately
uploaded `user-release-notes.txt` and `user-release-notes.html` contain user text
only; HTML is suitable for an update window. Test apps still have public updates
disabled and publish no Sparkle feed.

The immutable previous nightly and latest stable tags’ source trees form the
publication ledger, so a newer stable’s fragments do not repeat after an older
beta. The scheduler fetches tags as well as main, including stable tags on a
separate hotfix branch.
Before the first nightly, the last stable tag is the baseline; a separate hotfix
branch uses its common ancestor with main. Failed/draft releases do not consume
fragments. A successful local publication is also remembered if subsequent
cleanup fails or the release listing is stale. If GitHub has a newer published
nightly than local state, that newer tag remains the baseline. All fragments at the published
SHA, including overflow, count as covered; retain them for stable curation.

Preview without building, signing or publishing:

```
python3 scripts/user-release-notes.py --format sources
python3 scripts/user-release-notes.py --format text
python3 scripts/user-release-notes.py --format github
python3 scripts/user-release-notes.py --format html
```

Use `--base <previous-tag>` and `--head <commit>` for a specific range. The source
view includes every developer change and pending fragment; only this material
belongs in the notes. The default preview reads GitHub release metadata. On a feature branch, use
`--developer-head origin/main` to preview the already merged developer list
alongside that branch’s fragments. Actual releases always use one admitted main
SHA for both texts.

For a stable release, gather all fragments since the last stable, including the
intervening betas. Sort the material into highlights, improvements, fixes,
actions and omissions. Collapse by what the reader sees. Leave out internal
work and bugs introduced and fixed since the previous published version. Write
one to three introductory sentences, then only the sections needed: Highlights,
Before you update, Improvements, Fixes. Put changed defaults, requirements and
steps to take under Before you update; say what happens if you do nothing.

Write curated user-only HTML in `Distribution/release-notes/<version>.html` and
have another person read it. Pass it explicitly as `scripts/release.py
--release-notes <file>`: the stable tool refuses absent, missing or empty notes
before reading credentials or building. It signs those HTML bytes for Sparkle;
never pass the developer changelog. Stable publication still needs Silvio’s
approval. The writing method follows [gocassini’s two-reader approach](https://github.com/codemyriad/gocassini/pull/420).
